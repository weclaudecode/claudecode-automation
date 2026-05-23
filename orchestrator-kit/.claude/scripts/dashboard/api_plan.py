"""GET /api/plan — active plan state.json, reshaped for the frontend.

Mirrors `orchestrator.sh`'s active-plan selection: glob
`.claude/plans/*.state.json`, keep only `status == "in_progress"`, pick
the newest by mtime. No active plan is a normal state, not an error.
"""

from __future__ import annotations

import glob
import json
import os
import subprocess
from pathlib import Path

from flask import Blueprint, jsonify

from dashboard.app import json_envelope

bp = Blueprint("plan", __name__)

# Fields surfaced on every task. Optional fields (merged_at, blocked_reason)
# are appended only when present in the state file.
_TASK_FIELDS = ("title", "status", "depends_on", "touches", "issue", "pr", "retries")


def _repo_root() -> Path:
    # Flask serves from the repo root in normal operation, but the orchestrator
    # cd's into worktrees mid-tick — fall back to `git rev-parse` to stay
    # correct under either.
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        )
        return Path(out.stdout.strip())
    except (subprocess.CalledProcessError, FileNotFoundError):
        return Path(os.getcwd())


def _find_active_state_file(root: Path) -> Path | None:
    candidates = glob.glob(str(root / ".claude" / "plans" / "*.state.json"))
    active: list[tuple[float, Path]] = []
    for c in candidates:
        p = Path(c)
        try:
            with p.open() as f:
                doc = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        if doc.get("status") == "in_progress":
            active.append((p.stat().st_mtime, p))
    if not active:
        return None
    active.sort(key=lambda t: t[0], reverse=True)
    return active[0][1]


def _slug_from_plan_file(plan_file: str) -> str:
    base = Path(plan_file).stem  # PLAN-03-local-dashboard
    parts = base.split("-", 2)
    return parts[2] if len(parts) >= 3 else base


def _reshape_tasks(tasks: dict) -> list[dict]:
    out: list[dict] = []
    for k, v in tasks.items():
        try:
            n = int(k)
        except (TypeError, ValueError):
            continue
        entry: dict = {"n": n}
        for field in _TASK_FIELDS:
            entry[field] = v.get(field)
        if "merged_at" in v:
            entry["merged_at"] = v["merged_at"]
        if "blocked_reason" in v:
            entry["blocked_reason"] = v["blocked_reason"]
        out.append(entry)
    out.sort(key=lambda t: t["n"])
    return out


def _reshape(doc: dict) -> dict:
    plan_file = doc.get("plan_file", "")
    return {
        "plan_file": plan_file,
        "slug": _slug_from_plan_file(plan_file),
        "total_tasks": doc.get("total_tasks"),
        "status": doc.get("status"),
        "ingested_at": doc.get("ingested_at"),
        "tasks": _reshape_tasks(doc.get("tasks", {})),
    }


@bp.route("/api/plan")
def get_plan():
    root = _repo_root()
    state_file = _find_active_state_file(root)
    if state_file is None:
        return jsonify(json_envelope(data=None))
    try:
        with state_file.open() as f:
            doc = json.load(f)
    except FileNotFoundError:
        return jsonify(json_envelope(data=None, error="state file disappeared"))
    except json.JSONDecodeError as e:
        return jsonify(json_envelope(data=None, error=f"state file invalid json: {e}"))
    return jsonify(json_envelope(data=_reshape(doc)))
