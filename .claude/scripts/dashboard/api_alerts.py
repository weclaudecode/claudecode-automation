"""/api/alerts — high-signal operator alerts surfaced as cards.

Aggregates four sources the kit already knows about but currently
buries in the regular panels:

1. blocked tasks       (read from the active *.state.json)
2. orch:needs-robbie   (gh pr list, sensitive-merge holding queue)
3. monitor:finding     (gh issue list, the H1-H7 monitor agent output)
4. dead_orchestrator   (orchestrator.log tail; no recent tick = cron dead)

Per-collector failures are caught and surfaced via the envelope's
`error` field as a soft warning — a hung `gh` call must not blank the
strip. Each cache layer is independent so a failing collector can
recover next poll without poisoning the others.

Envelope shape (mirrors siblings):

    {"data": {"alerts": [<alert>, ...]}, "stale_at": ..., "error": null}

Alert shape:

    {
      "id":               "<kind>:<key>",        # stable hash for dedupe
      "severity":         "error" | "warn" | "info",
      "kind":             "blocked" | "needs_robbie" | "monitor" | "dead_orchestrator",
      "summary":          "<one-line operator-readable description>",
      "detail":           "<optional longer text>" | null,
      "link":             "<URL>" | null,
      "since":            "<iso8601>" | null,
      "suggested_action": "<short remediation hint>",
    }
"""

from __future__ import annotations

import datetime as _dt
import glob
import json
import os
import re
import subprocess
import threading
import time
from pathlib import Path

from flask import Blueprint, jsonify

from dashboard.app import json_envelope

bp = Blueprint("alerts", __name__)

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------

_GH_CACHE_TTL_SECONDS = 30
_LOCAL_CACHE_TTL_SECONDS = 10
_GH_TIMEOUT_SECONDS = 10
_DEFAULT_EXPECTED_TICK_MINUTES = 5

# Substring match against monitor finding titles — H1/H2/H4 are the
# heuristics whose patterns indicate "something is actually broken right
# now" vs the slower trend signals (H3 slow plan, H5 deadlock window,
# H6 test-fail, H7 sensitive-decisions audit), so they're warn-grade.
_URGENT_MONITOR_HEURISTICS = ("H1", "H2", "H4")

# `=== tick 2026-05-24T03:15:00Z ===` — pulled out of orchestrator.log
_TICK_RE = re.compile(r"^=== tick (\S+)")

# Plan state location relative to repo root.
_PLANS_GLOB = ".claude/plans/*.state.json"
_LOG_PATH = ".claude/state/orchestrator.log"

# ---------------------------------------------------------------------------
# Cache plumbing (one lock per source so collectors don't serialise)
# ---------------------------------------------------------------------------

_state_lock = threading.Lock()
_state_cache: tuple[float, list[dict], str | None] | None = None

_log_lock = threading.Lock()
_log_cache: tuple[float, dict | None, str | None] | None = None

_robbie_lock = threading.Lock()
_robbie_cache: tuple[float, list[dict], str | None] | None = None

_monitor_lock = threading.Lock()
_monitor_cache: tuple[float, list[dict], str | None] | None = None


def _expected_tick_minutes() -> int:
    raw = os.environ.get("ORCH_DASHBOARD_EXPECTED_TICK_MINUTES")
    if not raw:
        return _DEFAULT_EXPECTED_TICK_MINUTES
    try:
        n = int(raw)
        return n if n > 0 else _DEFAULT_EXPECTED_TICK_MINUTES
    except ValueError:
        return _DEFAULT_EXPECTED_TICK_MINUTES


# ---------------------------------------------------------------------------
# Collector: blocked tasks (from active state file)
# ---------------------------------------------------------------------------

def _find_active_state_file() -> Path | None:
    candidates: list[tuple[float, Path]] = []
    for c in glob.glob(_PLANS_GLOB):
        p = Path(c)
        try:
            with p.open() as f:
                doc = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        if doc.get("status") == "in_progress":
            candidates.append((p.stat().st_mtime, p))
    if not candidates:
        return None
    candidates.sort(key=lambda t: t[0], reverse=True)
    return candidates[0][1]


def _read_blocked_alerts() -> tuple[list[dict], str | None]:
    state_file = _find_active_state_file()
    if state_file is None:
        return [], None
    try:
        with state_file.open() as f:
            doc = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        return [], f"state file unreadable: {e}"

    plan_file = doc.get("plan_file") or state_file.name
    tasks = doc.get("tasks") or {}
    if not isinstance(tasks, dict):
        return [], "state file `tasks` is not an object"

    out: list[dict] = []
    for task_n, task in tasks.items():
        if not isinstance(task, dict):
            continue
        if task.get("status") != "blocked":
            continue
        reason = task.get("blocked_reason") or "unknown"
        title = task.get("title") or f"task {task_n}"
        out.append({
            "id": f"blocked:{plan_file}:{task_n}",
            "severity": "error",
            "kind": "blocked",
            "summary": f"task {task_n} blocked — {reason}",
            "detail": title,
            "link": None,
            "since": task.get("blocked_at"),
            "suggested_action": (
                f"reset task: jq '.tasks[\"{task_n}\"].status=\"pending\" | "
                f".tasks[\"{task_n}\"].retries=0 | "
                f"del(.tasks[\"{task_n}\"].blocked_at,.tasks[\"{task_n}\"].blocked_reason)' "
                f"{state_file} > /tmp/s && mv /tmp/s {state_file}"
            ),
        })
    return out, None


def _cached_blocked_alerts() -> tuple[list[dict], str | None]:
    global _state_cache
    now = time.monotonic()
    with _state_lock:
        if _state_cache is not None and (now - _state_cache[0]) < _LOCAL_CACHE_TTL_SECONDS:
            return list(_state_cache[1]), _state_cache[2]
        alerts, err = _read_blocked_alerts()
        _state_cache = (now, alerts, err)
        return list(alerts), err


# ---------------------------------------------------------------------------
# Collector: dead-orchestrator (from log tail)
# ---------------------------------------------------------------------------

def _last_tick_iso() -> tuple[str | None, str | None]:
    """Return (iso, error). iso is None if no tick marker found."""
    path = Path(_LOG_PATH)
    if not path.exists():
        return None, None
    try:
        # Tail-read by chunks from end so a 10 MiB log doesn't allocate a list
        # of 200k strings. Most tick markers land in the last 16 KiB.
        with path.open("rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            chunk = min(size, 65536)
            fh.seek(size - chunk)
            tail = fh.read().decode("utf-8", errors="replace").splitlines()
    except OSError as e:
        return None, f"log unreadable: {e}"

    last = None
    for line in tail:
        m = _TICK_RE.match(line)
        if m:
            last = m.group(1)
    return last, None


def _dead_orchestrator_alert() -> tuple[list[dict], str | None]:
    iso, err = _last_tick_iso()
    if err:
        return [], err
    if iso is None:
        # No tick markers in log — either fresh install or log rotated and the
        # current file's prelude doesn't have one yet. Stay quiet rather than
        # cry wolf.
        return [], None
    try:
        ts = _dt.datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return [], None
    now = _dt.datetime.now(_dt.timezone.utc)
    elapsed = (now - ts).total_seconds() / 60.0
    threshold = _expected_tick_minutes() * 2
    if elapsed < threshold:
        return [], None
    return [{
        "id": "dead_orchestrator:singleton",
        "severity": "error",
        "kind": "dead_orchestrator",
        "summary": f"no orchestrator tick in {int(elapsed)} minutes — is cron running?",
        "detail": (
            f"Last tick at {iso}; expected interval {_expected_tick_minutes()} min "
            f"(2x threshold = {threshold} min)."
        ),
        "link": None,
        "since": iso,
        "suggested_action": "check crontab / launchd / `/loop` runner, then tail .claude/state/orchestrator.log",
    }], None


def _cached_dead_orchestrator() -> tuple[list[dict], str | None]:
    global _log_cache
    now = time.monotonic()
    with _log_lock:
        if _log_cache is not None and (now - _log_cache[0]) < _LOCAL_CACHE_TTL_SECONDS:
            data, err = _log_cache[1], _log_cache[2]
            return list(data or []), err
        alerts, err = _dead_orchestrator_alert()
        _log_cache = (now, alerts, err)
        return list(alerts), err


# ---------------------------------------------------------------------------
# Collector: gh-backed alerts (needs-robbie, monitor)
# ---------------------------------------------------------------------------

def _run_gh(args: list[str]) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            ["gh", *args],
            capture_output=True,
            text=True,
            timeout=_GH_TIMEOUT_SECONDS,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except FileNotFoundError:
        return 127, "", "gh CLI not found on PATH"
    except subprocess.TimeoutExpired:
        return 124, "", f"gh timed out after {_GH_TIMEOUT_SECONDS}s"


def _detect_repo() -> tuple[str | None, str | None]:
    rc, out, err = _run_gh(
        ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]
    )
    if rc != 0:
        return None, (err or out).strip()[:500]
    repo = out.strip()
    return (repo, None) if repo else (None, "gh repo view returned empty")


def _fetch_needs_robbie() -> tuple[list[dict], str | None]:
    repo, err = _detect_repo()
    if repo is None:
        return [], err
    rc, out, err = _run_gh([
        "pr", "list",
        "--repo", repo,
        "--label", "orch:needs-robbie",
        "--state", "open",
        "--json", "number,title,url,createdAt",
        "--limit", "30",
    ])
    if rc != 0:
        return [], (err or out).strip()[:500]
    try:
        items = json.loads(out or "[]")
    except json.JSONDecodeError as e:
        return [], f"gh pr list parse failed: {e}"

    out_alerts: list[dict] = []
    for it in items:
        number = it.get("number")
        out_alerts.append({
            "id": f"needs_robbie:{number}",
            "severity": "warn",
            "kind": "needs_robbie",
            "summary": f"PR #{number} needs robbie — sensitive merge held for human review",
            "detail": it.get("title") or "",
            "link": it.get("url"),
            "since": it.get("createdAt"),
            "suggested_action": "review the PR, then `gh pr merge --squash --delete-branch <num>`",
        })
    return out_alerts, None


def _cached_needs_robbie() -> tuple[list[dict], str | None]:
    global _robbie_cache
    now = time.monotonic()
    with _robbie_lock:
        if _robbie_cache is not None and (now - _robbie_cache[0]) < _GH_CACHE_TTL_SECONDS:
            return list(_robbie_cache[1]), _robbie_cache[2]
        alerts, err = _fetch_needs_robbie()
        _robbie_cache = (now, alerts, err)
        return list(alerts), err


def _fetch_monitor_findings() -> tuple[list[dict], str | None]:
    repo, err = _detect_repo()
    if repo is None:
        return [], err
    rc, out, err = _run_gh([
        "issue", "list",
        "--repo", repo,
        "--label", "monitor:finding",
        "--state", "open",
        "--json", "number,title,labels,url,createdAt",
        "--limit", "30",
    ])
    if rc != 0:
        return [], (err or out).strip()[:500]
    try:
        items = json.loads(out or "[]")
    except json.JSONDecodeError as e:
        return [], f"gh issue list parse failed: {e}"

    out_alerts: list[dict] = []
    for it in items:
        number = it.get("number")
        title = it.get("title") or ""
        # Severity: warn if title mentions an urgent heuristic, else info.
        severity = "info"
        for h in _URGENT_MONITOR_HEURISTICS:
            if h in title:
                severity = "warn"
                break
        out_alerts.append({
            "id": f"monitor:{number}",
            "severity": severity,
            "kind": "monitor",
            "summary": f"monitor finding: {title}" if title else f"monitor finding #{number}",
            "detail": ", ".join(
                lbl.get("name", "") for lbl in (it.get("labels") or [])
                if isinstance(lbl, dict) and lbl.get("name") != "monitor:finding"
            ) or None,
            "link": it.get("url"),
            "since": it.get("createdAt"),
            "suggested_action": "investigate; close the issue once the underlying pattern clears",
        })
    return out_alerts, None


def _cached_monitor() -> tuple[list[dict], str | None]:
    global _monitor_cache
    now = time.monotonic()
    with _monitor_lock:
        if _monitor_cache is not None and (now - _monitor_cache[0]) < _GH_CACHE_TTL_SECONDS:
            return list(_monitor_cache[1]), _monitor_cache[2]
        alerts, err = _fetch_monitor_findings()
        _monitor_cache = (now, alerts, err)
        return list(alerts), err


# ---------------------------------------------------------------------------
# Route
# ---------------------------------------------------------------------------

_SEVERITY_RANK = {"error": 0, "warn": 1, "info": 2}


def _sort_key(alert: dict) -> tuple:
    sev = _SEVERITY_RANK.get(alert.get("severity"), 99)
    # Older alerts come first within the same severity — they're the ones that
    # have been festering longest.
    return (sev, alert.get("since") or "")


@bp.route("/api/alerts")
def alerts():
    collectors = [
        ("blocked", _cached_blocked_alerts),
        ("dead_orchestrator", _cached_dead_orchestrator),
        ("needs_robbie", _cached_needs_robbie),
        ("monitor", _cached_monitor),
    ]

    all_alerts: list[dict] = []
    errors: list[str] = []
    for name, fn in collectors:
        try:
            items, err = fn()
        except Exception as e:  # noqa: BLE001 — strip must never raise
            errors.append(f"alerts.{name}: {type(e).__name__}: {e}")
            continue
        if err:
            errors.append(f"alerts.{name}: {err}")
        all_alerts.extend(items)

    all_alerts.sort(key=_sort_key)

    return jsonify(json_envelope(
        data={"alerts": all_alerts},
        error="; ".join(errors) if errors else None,
    ))
