"""Config endpoint — introspects tunables and their resolved sources.

Read-only by design. The dashboard never mutates config; operators edit
env, settings.json, or plan state.json directly and refresh the panel.

The TUNABLES list below is the **canonical source of truth** for which
orchestrator knobs the dashboard surfaces. To add a new tunable:

1. Append a `(name, default, description)` tuple here.
2. Update the table in `orchestrator-kit/docs/DASHBOARD.md`.
3. Update `README.md`'s "Cost knobs" table if it's cost-relevant.

Anything not in this list won't appear in the dashboard config panel
even if it's read by the orchestrator — that's intentional, so the
panel stays a curated operator view rather than an env dump.
"""

from __future__ import annotations

import glob
import json
import os
from pathlib import Path

from flask import Blueprint, jsonify

from dashboard.app import json_envelope

bp = Blueprint("config", __name__)

# (env-var name, default value as string, human description)
TUNABLES = [
    ("ORCH_MAX_PARALLEL",     "1",        "Max parallel workers per tick"),
    ("ORCH_WORKER_MODEL",     "sonnet",   "Claude model (sonnet|opus)"),
    ("ORCH_MAX_TURNS",        "30",       "claude -p --max-turns cap"),
    ("ORCH_AUTO_RECOMMENDED", "0",        "Default auto-resolve for ambiguous decisions"),
    ("ORCH_LOG_MAX_BYTES",    "10485760", "Log rotation threshold (bytes)"),
    ("ORCH_DASHBOARD_PORT",   "5174",     "Dashboard Flask port"),
]

SETTINGS_PATH = Path(".claude/settings.json")
PLANS_GLOB = ".claude/plans/*.state.json"


def _env_entries() -> list[dict]:
    """Resolve each TUNABLE against os.environ, defaulting otherwise."""
    out: list[dict] = []
    for name, default, description in TUNABLES:
        if name in os.environ:
            current = os.environ[name]
            source = "env"
        else:
            current = default
            source = "default"
        out.append({
            "name": name,
            "source": source,
            "current": current,
            "default": default,
            "description": description,
        })
    return out


def _flatten(prefix: str, value) -> list[tuple[str, str]]:
    """Flatten a nested settings/state value into (dotted-key, string) pairs.

    Lists and scalars are emitted as a single entry; dicts recurse. We
    keep the serialised value short — the config panel renders a table,
    not arbitrarily-nested JSON.
    """
    if isinstance(value, dict):
        items: list[tuple[str, str]] = []
        for k, v in value.items():
            items.extend(_flatten(f"{prefix}.{k}" if prefix else k, v))
        return items
    # Lists/scalars: json-encode so booleans surface as "false" not "False"
    # and nested lists stay legible.
    try:
        rendered = json.dumps(value, ensure_ascii=False)
    except (TypeError, ValueError):
        rendered = str(value)
    return [(prefix, rendered)]


def _settings_entries() -> list[dict]:
    """Include relevant keys from .claude/settings.json (hooks etc.).

    Optional file — absent settings.json simply yields zero entries.
    """
    if not SETTINGS_PATH.exists():
        return []
    try:
        raw = json.loads(SETTINGS_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    out: list[dict] = []
    for key, rendered in _flatten("", raw):
        out.append({
            "name": key,
            "source": "settings.json",
            "current": rendered,
            "default": None,
            "description": f"settings.json key: {key}",
        })
    return out


def _active_state_file() -> Path | None:
    """Newest in_progress *.state.json — mirrors orchestrator.sh lines 94-96.

    We re-implement the lookup here rather than import from another
    dashboard module because Task 3 (/api/plan) and this endpoint may
    land out of order; keeping the logic local avoids a cross-module
    dependency on a peer that doesn't exist yet.
    """
    candidates = []
    for path in glob.glob(PLANS_GLOB):
        try:
            data = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if data.get("status") == "in_progress":
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                continue
            candidates.append((mtime, path))
    if not candidates:
        return None
    candidates.sort()  # ascending mtime; last is newest
    return Path(candidates[-1][1])


def _plan_state_entries() -> list[dict]:
    """Per-plan overrides: auto_recommended + auto_merge_overrides."""
    state_path = _active_state_file()
    if state_path is None:
        return []
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []

    out: list[dict] = []

    if "auto_recommended" in state:
        out.append({
            "name": "auto_recommended",
            "source": "plan-state",
            "current": json.dumps(state["auto_recommended"]),
            "default": None,
            "description": f"Per-plan override of ORCH_AUTO_RECOMMENDED (from {state_path.name})",
        })

    overrides = state.get("auto_merge_overrides") or {}
    if isinstance(overrides, dict):
        # Sort by task number when possible for stable ordering.
        def _sort_key(k: str):
            try:
                return (0, int(k))
            except ValueError:
                return (1, k)

        for task_n in sorted(overrides.keys(), key=_sort_key):
            val = overrides[task_n]
            out.append({
                "name": f"auto_merge_overrides.{task_n}",
                "source": "plan-state",
                "current": json.dumps(val),
                "default": None,
                "description": f"Per-task auto-merge override for task {task_n}",
            })

    return out


@bp.route("/api/config")
def config():
    tunables = _env_entries() + _settings_entries() + _plan_state_entries()
    return jsonify(json_envelope(data={"tunables": tunables}))
