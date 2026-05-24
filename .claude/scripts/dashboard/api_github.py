"""GitHub endpoint — wraps `gh` CLI for open issues + recent PRs.

Thin proxy around `gh issue list` and `gh pr list` with a 30-second
in-memory cache. The frontend polls every 5s; without caching every
poll would shell out twice, hammering `gh` and the GitHub API.

`gh` reads its own keyring — we never log env or stdin, only trim
stderr on failure for the error envelope.
"""

from __future__ import annotations

import json
import subprocess
import threading
import time

from flask import Blueprint, jsonify

from dashboard.app import json_envelope

bp = Blueprint("github", __name__)

_CACHE_TTL_SECONDS = 30
_GH_TIMEOUT_SECONDS = 10

_lock = threading.Lock()
_repo_cache: str | None = None
_payload_cache: tuple[float, dict] | None = None  # (timestamp, payload)


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
    global _repo_cache
    if _repo_cache is not None:
        return _repo_cache, None
    rc, out, err = _run_gh(["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"])
    if rc != 0:
        return None, (err or out).strip()[:500]
    repo = out.strip()
    if not repo:
        return None, "gh repo view returned empty nameWithOwner"
    _repo_cache = repo
    return repo, None


def _fetch_payload() -> tuple[dict | None, str | None]:
    repo, err = _detect_repo()
    if repo is None:
        return None, err

    rc, out, err = _run_gh([
        "issue", "list",
        "--repo", repo,
        "--state", "open",
        "--json", "number,title,labels,url",
        "--limit", "50",
    ])
    if rc != 0:
        return None, (err or out).strip()[:500]
    try:
        issues_raw = json.loads(out or "[]")
    except json.JSONDecodeError as e:
        return None, f"failed to parse gh issue list output: {e}"

    rc, out, err = _run_gh([
        "pr", "list",
        "--repo", repo,
        "--state", "all",
        "--json", "number,title,state,mergedAt,url,statusCheckRollup",
        "--limit", "30",
    ])
    if rc != 0:
        return None, (err or out).strip()[:500]
    try:
        prs_raw = json.loads(out or "[]")
    except json.JSONDecodeError as e:
        return None, f"failed to parse gh pr list output: {e}"

    open_issues = [
        {
            "number": item.get("number"),
            "title": item.get("title", ""),
            "labels": [lbl.get("name", "") for lbl in (item.get("labels") or [])],
            "url": item.get("url", ""),
        }
        for item in issues_raw
    ]
    open_issues.sort(key=lambda i: i.get("number") or 0, reverse=True)

    recent_prs = [
        {
            "number": item.get("number"),
            "title": item.get("title", ""),
            "state": item.get("state", ""),
            "merged_at": item.get("mergedAt"),
            "url": item.get("url", ""),
            "ci_state": _derive_ci_state(item.get("statusCheckRollup")),
        }
        for item in prs_raw
    ]
    # Most-recently-merged first; un-merged (merged_at is None) fall to the
    # bottom and are ordered by number desc among themselves.
    recent_prs.sort(
        key=lambda p: (
            0 if p["merged_at"] else 1,
            # negative timestamp for desc within merged group; empty string for unmerged
            -_to_epoch(p["merged_at"]) if p["merged_at"] else 0,
            -(p.get("number") or 0),
        )
    )

    return {"open_issues": open_issues, "recent_prs": recent_prs}, None


def _derive_ci_state(rollup) -> str | None:
    """Collapse `gh`'s per-check rollup into a single state for the dot.

    `statusCheckRollup` is a list of per-check objects whose shape varies
    (status checks expose `state`, check-runs expose `conclusion`+`status`).
    We treat the union: any failure dominates, else any pending wins, else
    success. An empty/missing rollup means "no checks configured" — render
    as None so the frontend shows a dash instead of a misleading green dot.
    """
    if not isinstance(rollup, list) or not rollup:
        return None
    has_pending = False
    for check in rollup:
        if not isinstance(check, dict):
            continue
        # Normalise to an upper-case verdict string drawn from whichever
        # field is populated. `conclusion` is the post-completion verdict
        # for check-runs; `status` is the in-flight one; `state` is the
        # status-checks field.
        verdict = (
            (check.get("conclusion") or check.get("state") or check.get("status") or "")
            .upper()
        )
        if verdict in ("FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED"):
            return "FAILURE"
        if verdict in ("PENDING", "IN_PROGRESS", "QUEUED", "WAITING", "EXPECTED"):
            has_pending = True
    return "PENDING" if has_pending else "SUCCESS"


def _to_epoch(iso: str | None) -> float:
    if not iso:
        return 0.0
    # gh emits RFC3339 like "2026-05-23T01:02:03Z"; treat 'Z' as UTC.
    try:
        from datetime import datetime
        s = iso.replace("Z", "+00:00")
        return datetime.fromisoformat(s).timestamp()
    except (ValueError, TypeError):
        return 0.0


@bp.route("/api/github")
def github():
    global _payload_cache
    now = time.monotonic()
    with _lock:
        if _payload_cache is not None and (now - _payload_cache[0]) < _CACHE_TTL_SECONDS:
            return jsonify(json_envelope(data=_payload_cache[1]))

        data, err = _fetch_payload()
        if err is not None:
            return jsonify(json_envelope(data=None, error=err))
        _payload_cache = (now, data)
        return jsonify(json_envelope(data=data))
