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
import os
import re
import shlex
import subprocess
from pathlib import Path

from flask import Blueprint, jsonify

from dashboard.app import json_envelope

bp = Blueprint("workers", __name__)

_PS_TIMEOUT_SECONDS = 5
_ACTIVE_WORKTREES_FILE = ".claude/state/active_worktrees.txt"

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


def _list_worktrees() -> list[dict]:
    repo_root = Path.cwd()
    manifest = repo_root / _ACTIVE_WORKTREES_FILE
    if not manifest.exists():
        return []
    out: list[dict] = []
    try:
        raw_lines = manifest.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
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
        })
    return out


@bp.route("/api/workers")
def workers():
    processes, err = _list_processes()
    worktrees = _list_worktrees()
    data = {"processes": processes, "active_worktrees": worktrees}
    return jsonify(json_envelope(data=data, error=err))
