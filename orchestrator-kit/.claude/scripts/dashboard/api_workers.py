"""Workers endpoint — lists active `claude -p` processes + worktrees.

Process side: `ps -axo pid,lstart,command` filtered to claude workers
running with `-p`/`--print` (the orchestrator's autonomous spawn mode).
We avoid `ps aux | grep` because grep self-matches and PATH can drift
under cron — `ps -axo` with explicit columns is deterministic.

Worktree side: read `.claude/state/active_worktrees.txt`, the manifest
maintained by `register_worktree`/`unregister_worktree` in
`_dispatcher_lib.sh`. The manifest stores ONE path per line (not the
tab-separated triple the original PLAN-03 sketch suggested) — branch
and task number are derived from the path's `wt-plan<NN>-t<M>` shape
and the kit's `claude/plan-<NN>-task-<M>` branch convention.
"""

from __future__ import annotations

import datetime as _dt
import json
import logging
import os
import re
import shlex
import subprocess
from pathlib import Path

from flask import Blueprint, jsonify

from dashboard.app import json_envelope

bp = Blueprint("workers", __name__)

log = logging.getLogger("dashboard")

_PS_TIMEOUT_SECONDS = 5
_GIT_REV_PARSE_TIMEOUT_SECONDS = 2
_ACTIVE_WORKTREES_FILE = ".claude/state/active_worktrees.txt"
_STATE_DIR = ".claude/state"


def _init_repo_root() -> Path:
    # Resolve the repo root via `git rev-parse --show-toplevel`. Flask is
    # often launched from outside the repo root (systemd ExecStart, cron
    # wrappers) — using Path.cwd() there silently produces a tree that
    # contains no `.claude/state/`, the worker panel goes blank, and the
    # operator has no signal that the dashboard is mis-anchored. The
    # subprocess result is cached at module load (see _REPO_ROOT below)
    # so we pay this cost once per process, not once per /api/workers
    # request. Falls back to Path.cwd() when git isn't on PATH or we're
    # not in a work tree — same defensive default as before, but now the
    # successful case is anchored correctly.
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=_GIT_REV_PARSE_TIMEOUT_SECONDS,
            check=True,
        )
        return Path(proc.stdout.strip())
    except (FileNotFoundError, subprocess.TimeoutExpired,
            subprocess.CalledProcessError, OSError):
        return Path.cwd()


_REPO_ROOT: Path = _init_repo_root()

# Last-log preview is rendered into the Active Workers panel as a single
# line. 200 chars keeps it readable in the narrow worker card without
# horizontal scroll; longer tails get an ellipsis.
_LAST_LOG_PREVIEW_MAX = 200

# Tool-use input keys ranked by "most descriptive when shown alone". Bash
# tasks usually have a `description`; file ops have `file_path`; search
# tools have `pattern` or `query`. Whichever hits first wins.
_TOOL_INPUT_SUMMARY_KEYS = (
    "description", "command", "file_path", "path", "pattern", "query", "url",
)

# wt-plan01-t3, wt-plan12-t10, etc. — see launch-worker.sh.
_WT_NAME_RE = re.compile(r"wt-plan(\d+)-t(\d+)$")

# macOS `ps -axo ... lstart ...` emits "Fri 23 May 14:02:11 2026"; on
# Linux/coreutils the same column is "Fri May 23 14:02:11 2026". Try
# both — _parse_lstart falls back to the raw string if neither matches.
_LSTART_FORMATS = (
    "%a %d %b %H:%M:%S %Y",
    "%a %b %d %H:%M:%S %Y",
)

# Redaction: any token shaped KEY=VALUE whose KEY contains any of these
# substrings (case-insensitive) is treated as sensitive. We over-redact
# rather than try to enumerate every credential env-var name — a false
# positive just hides a benign value from the dashboard, a false negative
# leaks a secret to anyone who can read localhost:5174.
_SENSITIVE_KEY_FRAGMENTS = (
    "TOKEN", "SECRET", "KEY", "PASSWORD", "PASSWD", "AUTH", "CREDENTIAL",
)
_SENSITIVE_KEY_PREFIXES = ("AWS_", "GITHUB_", "ANTHROPIC_", "GH_")
_KV_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.DOTALL)

# Secondary scrub: catches KEY=VALUE pairs embedded inside an outer token
# (e.g. `bash -c 'AWS_SECRET_ACCESS_KEY=xxx claude -p ...'` where the whole
# quoted string is one shlex token). Bounded value match — stops at the
# next whitespace, quote, or semicolon so we don't eat the rest of the line.
_INNER_KV_RE = re.compile(
    r"\b([A-Za-z_][A-Za-z0-9_]*)=([^\s'\";]+)"
)


def _is_sensitive_key(key: str) -> bool:
    upper = key.upper()
    if any(upper.startswith(p) for p in _SENSITIVE_KEY_PREFIXES):
        return True
    return any(frag in upper for frag in _SENSITIVE_KEY_FRAGMENTS)


def _sanitize_cmdline(cmdline: str) -> str:
    # Tokenize the way a shell would so we catch `FOO=bar claude -p ...`
    # prefixes. If shlex chokes on weird quoting, fall back to a regex
    # sweep over whitespace-split tokens — better to ship a partial scrub
    # than a stack trace.
    try:
        tokens = shlex.split(cmdline, posix=True)
    except ValueError:
        tokens = cmdline.split()

    redacted_tokens: list[str] = []
    for tok in tokens:
        m = _KV_RE.match(tok)
        if m and _is_sensitive_key(m.group(1)):
            redacted_tokens.append(f"{m.group(1)}=<redacted>")
            continue
        # Secondary scrub for KEY=VALUE pairs nested inside a quoted arg
        # (e.g. the contents of `bash -c '...'`). Whole-string regex sub.
        def _maybe_redact(match: re.Match) -> str:
            key = match.group(1)
            return f"{key}=<redacted>" if _is_sensitive_key(key) else match.group(0)
        redacted_tokens.append(_INNER_KV_RE.sub(_maybe_redact, tok))
    # shlex.join would re-quote everything; we only need a readable
    # cmdline for the dashboard, so a plain space-join is fine.
    return " ".join(redacted_tokens)


def _parse_lstart(raw: str) -> str:
    cleaned = raw.strip()
    for fmt in _LSTART_FORMATS:
        try:
            dt = _dt.datetime.strptime(cleaned, fmt)
            # ps prints local time; treat naive as local for the dashboard.
            return dt.astimezone().isoformat()
        except ValueError:
            continue
    return cleaned


def _looks_like_claude_worker(cmdline: str) -> bool:
    if "claude" not in cmdline:
        return False
    tokens = cmdline.split()
    return any(t == "-p" or t == "--print" for t in tokens)


def _trim_to_one_line(text: str) -> str:
    # Collapse all whitespace runs (incl. newlines) to a single space, then
    # truncate with an ellipsis. The panel renders one row per worker, so
    # the field must never contain a newline regardless of what the model
    # emitted.
    flat = " ".join(text.split())
    if len(flat) > _LAST_LOG_PREVIEW_MAX:
        return flat[: _LAST_LOG_PREVIEW_MAX - 1].rstrip() + "…"
    return flat


def _tool_use_summary(name: str, input_obj: object) -> str:
    if not isinstance(input_obj, dict):
        return ""
    for key in _TOOL_INPUT_SUMMARY_KEYS:
        val = input_obj.get(key)
        if isinstance(val, str) and val.strip():
            return f"{key}={val}"
    for k, v in input_obj.items():
        if isinstance(v, str) and v.strip():
            return f"{k}={v}"
    return ""


def _meaningful_text_from_event(event: object) -> str | None:
    # Three known event shapes from `claude -p`:
    #   1. Final result:  {"type":"result","result":"...","is_error":bool}
    #      — what --output-format json emits as a single object today.
    #   2. Assistant msg: {"type":"assistant","message":{"content":[blocks]}}
    #      — stream-json shape; blocks are {type:"text"} or {type:"tool_use"}.
    #   3. Standalone tool_use event (some stream variants).
    if not isinstance(event, dict):
        return None
    ev_type = event.get("type")
    if ev_type == "result":
        if event.get("is_error"):
            err = event.get("error") or event.get("result")
            return f"error: {err}" if isinstance(err, str) and err.strip() else "error"
        result = event.get("result")
        if isinstance(result, str) and result.strip():
            return result
        return None
    if ev_type == "assistant":
        msg = event.get("message")
        if isinstance(msg, dict):
            content = msg.get("content")
            if isinstance(content, list):
                # Walk from end — most recent block wins. text > tool_use.
                for block in reversed(content):
                    if not isinstance(block, dict):
                        continue
                    btype = block.get("type")
                    if btype == "text":
                        txt = block.get("text")
                        if isinstance(txt, str) and txt.strip():
                            return txt
                    elif btype == "tool_use":
                        name = block.get("name") or "tool"
                        summary = _tool_use_summary(name, block.get("input"))
                        return f"→ {name}({summary})" if summary else f"→ {name}"
        return None
    if ev_type == "tool_use":
        name = event.get("name") or "tool"
        summary = _tool_use_summary(name, event.get("input"))
        return f"→ {name}({summary})" if summary else f"→ {name}"
    return None


def _last_log_for_task(task_n: int) -> str | None:
    # Best-effort: NEVER raise. Returns a one-line preview of the most
    # recent meaningful message in the worker's newest run JSON, or None
    # if the file is missing, empty, malformed, or has no surfaceable
    # text. The Active Workers panel treats None as "no preview yet".
    #
    # Expected failures (OSError, json.JSONDecodeError, UnicodeDecodeError)
    # are caught specifically. A WARNING breadcrumb is emitted when a
    # run-file existed but yielded no preview because JSON decode failed —
    # without it, an operator looking at an empty `last_log` column has
    # no way to distinguish "no run-file yet" from "worker wrote garbage".
    # Anything outside the expected set is still caught (the panel must
    # never crash on a single bad file) but is logged as a warning so
    # programmer errors don't get silently swallowed for weeks.
    state_dir = _REPO_ROOT / _STATE_DIR
    if not state_dir.is_dir():
        return None

    try:
        matches = sorted(
            state_dir.glob(f"run-plan*-t{task_n}-r*.json"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        if not matches:
            return None
        run_file = matches[0]
        raw = run_file.read_text(encoding="utf-8", errors="replace")
    except (OSError, UnicodeDecodeError) as e:
        log.warning(
            "api_workers: failed reading run-file for task %s in %s: %s: %s",
            task_n, state_dir, type(e).__name__, e,
        )
        return None
    except Exception as e:  # noqa: BLE001 — defensive panel boundary
        log.warning(
            "api_workers: unexpected error listing run-files for task %s: %s: %s",
            task_n, type(e).__name__, e,
        )
        return None

    if not raw.strip():
        return None

    decode_errors = 0

    # Single-object JSON first (current `--output-format json` shape).
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError:
        doc = None
        decode_errors += 1
    except Exception as e:  # noqa: BLE001 — defensive panel boundary
        log.warning(
            "api_workers: unexpected json.loads error on %s: %s: %s",
            run_file, type(e).__name__, e,
        )
        return None

    if doc is not None:
        preview = _meaningful_text_from_event(doc)
        if preview:
            return _trim_to_one_line(preview)

    # JSONL fallback (future stream-json output). Walk from the tail
    # so we surface the most recent event, not the first.
    for line in reversed(raw.splitlines()):
        stripped = line.strip()
        if not stripped:
            continue
        try:
            event = json.loads(stripped)
        except json.JSONDecodeError:
            decode_errors += 1
            continue
        preview = _meaningful_text_from_event(event)
        if preview:
            return _trim_to_one_line(preview)

    if decode_errors > 0:
        log.warning(
            "api_workers: %s for task %s has %d JSON decode error(s); "
            "no preview surfaced — file may be corrupt or mid-write",
            run_file, task_n, decode_errors,
        )
    return None


def _list_processes() -> tuple[list[dict], str | None]:
    try:
        proc = subprocess.run(
            ["ps", "-axo", "pid,lstart,command"],
            capture_output=True,
            text=True,
            timeout=_PS_TIMEOUT_SECONDS,
        )
    except FileNotFoundError:
        return [], "ps command not found on PATH"
    except subprocess.TimeoutExpired:
        return [], f"ps timed out after {_PS_TIMEOUT_SECONDS}s"

    if proc.returncode != 0:
        return [], (proc.stderr or proc.stdout).strip()[:500]

    out: list[dict] = []
    lines = proc.stdout.splitlines()
    for line in lines[1:]:  # skip header row
        line = line.rstrip()
        if not line:
            continue
        parts = line.split(None, 6)
        # pid + 5 lstart tokens + command = 7 fields minimum
        if len(parts) < 7:
            continue
        pid_raw = parts[0]
        lstart_raw = " ".join(parts[1:6])
        cmdline = parts[6]
        if not _looks_like_claude_worker(cmdline):
            continue
        try:
            pid = int(pid_raw)
        except ValueError:
            continue
        out.append({
            "pid": pid,
            "started_at": _parse_lstart(lstart_raw),
            "cmdline": _sanitize_cmdline(cmdline),
        })
    return out, None


def _derive_branch_and_task(path: str) -> tuple[str | None, int | None]:
    name = os.path.basename(path.rstrip("/"))
    m = _WT_NAME_RE.search(name)
    if not m:
        return None, None
    plan_n, task_n = m.group(1), m.group(2)
    return f"claude/plan-{plan_n}-task-{task_n}", int(task_n)


def _list_worktrees() -> tuple[list[dict], str | None]:
    # Returns (worktrees, error). `error` is None on the happy path and
    # `"<relpath>: <ExceptionType>: <msg>"` when the manifest exists but
    # can't be read — the /api/workers route folds that string into the
    # data.errors[] channel so a permissions glitch or a corrupt manifest
    # doesn't silently empty the Active Worktrees panel.
    repo_root = _REPO_ROOT
    manifest = repo_root / _ACTIVE_WORKTREES_FILE
    if not manifest.exists():
        return [], None
    out: list[dict] = []
    try:
        raw_lines = manifest.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as e:
        return [], f"{_ACTIVE_WORKTREES_FILE}: {type(e).__name__}: {e}"
    for raw in raw_lines:
        line = raw.strip()
        if not line:
            continue
        # Manifest currently stores one path per line; tolerate a future
        # tab-separated <path>\t<branch>\t<task_n> shape too.
        if "\t" in line:
            fields = line.split("\t")
            path = fields[0]
            branch = fields[1] if len(fields) > 1 and fields[1] else None
            task_n_raw = fields[2] if len(fields) > 2 and fields[2] else None
            try:
                task_n: int | None = int(task_n_raw) if task_n_raw else None
            except ValueError:
                task_n = None
        else:
            path = line
            branch, task_n = None, None

        # Resolve against repo root so the manifest's relative
        # "../wt-planNN-tM" entries (see launch-worker.sh) get checked
        # against the actual on-disk location.
        candidate = Path(path)
        resolved = candidate if candidate.is_absolute() else (repo_root / candidate)
        if not resolved.exists():
            continue

        if branch is None or task_n is None:
            derived_branch, derived_task = _derive_branch_and_task(path)
            if branch is None:
                branch = derived_branch
            if task_n is None:
                task_n = derived_task

        out.append({
            "path": path,
            "branch": branch,
            "task_n": task_n,
            "last_log": _last_log_for_task(task_n) if task_n is not None else None,
        })
    return out, None


@bp.route("/api/workers")
def workers():
    # Per-source failures are folded into data["errors"] (list[str]) so
    # they surface alongside the data the frontend actually reads. The
    # envelope's top-level `error` field is left null on purpose: the
    # board.js renderer (and the workers panel renderer in dashboard.js)
    # ignore envelope.error when data is also present, so any per-source
    # failure routed there was effectively invisible to the operator.
    processes, proc_err = _list_processes()
    worktrees, manifest_err = _list_worktrees()
    errors: list[str] = []
    if proc_err:
        errors.append(f"processes: {proc_err}")
    if manifest_err:
        errors.append(f"worktrees: {manifest_err}")
    data = {
        "processes": processes,
        "active_worktrees": worktrees,
        "errors": errors,
    }
    return jsonify(json_envelope(data=data))
