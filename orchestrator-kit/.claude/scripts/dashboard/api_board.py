"""GET /api/board — unified Mission Centre payload composer.

Single endpoint backing the entire Mission Centre view: 7-column kanban
board, Active Workers panel, Plan Status, cost rollup, log tail, recent
activity, and GitHub panel. Frontend polls this every 5 s.

Architecture
------------
Pure column-builder `build_board(active_states, archived_states, gh_issues,
gh_prs, pr_labels, workers_pool, jokes_pool, *, cost_fn, utc_date)` is the
testable seam — no IO inside. The Flask route is thin glue that loads
each source under try/except, records partial failures in an `errors`
array (the frontend renders per-panel "data unavailable" banners), and
hands clean inputs to `build_board`.

Determinism — see `_stable_hash` for why we use md5 instead of Python's
built-in `hash()`. Column precedence — sensitive in-review tasks land
in Blocked, ahead of the in_review branching. Merged-but-not-yet-swept
PRs land in Done, ahead of the closed-PR branching.

PR labels come from `gh pr list --json number,labels` with a 30 s
in-memory cache. The existing api_github cache doesn't request labels
and changing its query shape isn't worth the blast radius.
"""

from __future__ import annotations

import datetime as _dt
import glob
import hashlib
import json
import logging
import re
import subprocess
import threading
import time
from pathlib import Path
from typing import Any, Callable

from flask import Blueprint, jsonify

from dashboard.app import json_envelope
from dashboard.api_costs import cost_for_task, cost_today
from dashboard.api_github import _fetch_payload as _gh_fetch_payload
from dashboard.api_workers import _list_worktrees as _list_worktrees_for_board

bp = Blueprint("board", __name__)
log = logging.getLogger("dashboard.board")

# ── Constants ──────────────────────────────────────────────────────────────

_COLUMN_NAMES = (
    "backlog", "todo", "in_progress", "ready_for_review",
    "in_review", "blocked", "done",
)

_ARGUS_NAME = "Argus"

_PR_LABEL_CACHE_TTL_SECONDS = 30
_GH_TIMEOUT_SECONDS = 10
_EVENTS_TAIL_LINES = 20
_LOG_TAIL_LINES = 40

_DEFAULT_LOG_PATH = Path(".claude/state/orchestrator.log")
_DEFAULT_EVENTS_PATH = Path(".claude/state/events.jsonl")

_BRANCH_PLAN_RE = re.compile(r"plan-(\d+)")
_LOG_TIME_RE = re.compile(r"\b(\d{2}:\d{2}:\d{2})\b")


# ── Agent identity ─────────────────────────────────────────────────────────

def _stable_hash(s: str) -> int:
    # md5 is deterministic across Python processes; Python's built-in
    # hash() is PYTHONHASHSEED-randomized, which would silently break
    # the "same (plan, task) → same agent" acceptance criterion every
    # time the dashboard restarted.
    return int.from_bytes(hashlib.md5(s.encode("utf-8")).digest()[:8], "big")


def agent_for_task(
    plan_slug: str, task_n: int, workers_pool: list[str], role: str = "worker",
) -> dict[str, str]:
    """Deterministic agent assignment.

    Reviewer role is hard-pinned to Argus. Worker / iterator roles map
    (plan, task) → workers_pool[ hash % len(pool) ]. Returns a stub
    `{name, avatar_seed, role}` shape; the frontend builds the avatar
    URL from `avatar_seed` (DiceBear bottts).
    """
    if role == "reviewer":
        return {"name": _ARGUS_NAME, "avatar_seed": _ARGUS_NAME, "role": "reviewer"}
    if not workers_pool:
        return {"name": "?", "avatar_seed": "?", "role": role}
    idx = _stable_hash(f"{plan_slug}:{task_n}") % len(workers_pool)
    name = workers_pool[idx]
    return {"name": name, "avatar_seed": name, "role": role}


def joke_for_task(
    plan_slug: str, task_n: int, jokes_pool: list[str], utc_date: str,
) -> str | None:
    if not jokes_pool:
        return None
    idx = _stable_hash(f"{plan_slug}:{task_n}:{utc_date}") % len(jokes_pool)
    return jokes_pool[idx]


# ── Static asset loaders (agents.json, blocked_jokes.json) ────────────────

def _load_agents_and_jokes() -> tuple[list[str], list[str], list[str]]:
    """Return (workers, jokes, errors).

    `errors` is a list of human-readable strings (zero or more) — agents
    and jokes can fail independently, so a single optional string would
    drop one when both surface.
    """
    # CWD fallback exists so tests can stub static/ via a tmpdir.
    candidates = [
        Path(__file__).resolve().parent / "static",
        Path(".claude/scripts/dashboard/static"),
        Path("static"),
    ]
    static_dir = next((p for p in candidates if (p / "agents.json").is_file()), None)
    if static_dir is None:
        return [], [], ["static/agents.json not found"]

    errors: list[str] = []
    try:
        with (static_dir / "agents.json").open("r", encoding="utf-8") as f:
            agents = json.load(f)
        workers = [
            a["name"] for a in agents
            if isinstance(a, dict) and a.get("role") == "worker" and isinstance(a.get("name"), str)
        ]
    except (OSError, ValueError) as e:
        return [], [], [f"agents.json: {type(e).__name__}: {e}"]

    jokes: list[str] = []
    jokes_file = static_dir / "blocked_jokes.json"
    if jokes_file.is_file():
        try:
            with jokes_file.open("r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, list):
                jokes = [j for j in data if isinstance(j, str)]
        except (OSError, ValueError) as e:
            msg = f"blocked_jokes.json: {type(e).__name__}: {e}"
            log.warning("api_board: %s", msg)
            errors.append(msg)
            jokes = []
    return workers, jokes, errors


# ── State file loaders ─────────────────────────────────────────────────────

def _read_state_files() -> tuple[list[tuple[str, dict]], list[tuple[str, dict]], list[str]]:
    """Return (active_states, archived_states, errors).

    Each tuple is (path, parsed_dict). Errors are human-readable strings.
    """
    errors: list[str] = []
    active: list[tuple[str, dict]] = []
    archived: list[tuple[str, dict]] = []

    for p in sorted(glob.glob(".claude/plans/*.state.json")):
        try:
            with open(p, "r", encoding="utf-8") as f:
                active.append((p, json.load(f)))
        except (OSError, ValueError) as e:
            errors.append(f"{p}: {type(e).__name__}: {e}")

    for p in sorted(glob.glob(".claude/plans/archive/*.state.json")):
        try:
            with open(p, "r", encoding="utf-8") as f:
                archived.append((p, json.load(f)))
        except (OSError, ValueError) as e:
            errors.append(f"{p}: {type(e).__name__}: {e}")

    return active, archived, errors


def _plan_slug_short(state: dict) -> str:
    """'PLAN-06-mission-centre' → 'PLAN-06' — the short slug used as agent key."""
    base = Path(state.get("plan_file") or "").stem
    parts = base.split("-", 2)
    if len(parts) >= 2 and parts[0] == "PLAN":
        return "-".join(parts[:2])
    return base


def _plan_slug_full(state: dict) -> str:
    return Path(state.get("plan_file") or "").stem


# ── GH PR labels fetcher (30 s cache) ─────────────────────────────────────

_pr_meta_lock = threading.Lock()
# Cache entry: (mono_time, labels_by_pr). Error responses cache an empty
# dict so an outage doesn't re-shell `gh` on every 5 s frontend poll.
_pr_meta_cache: tuple[float, dict[int, list[str]]] | None = None


def _fetch_pr_labels() -> tuple[dict[int, list[str]], str | None]:
    """Open PRs only → labels list per PR number."""
    global _pr_meta_cache
    now = time.monotonic()
    with _pr_meta_lock:
        if _pr_meta_cache and (now - _pr_meta_cache[0]) < _PR_LABEL_CACHE_TTL_SECONDS:
            return _pr_meta_cache[1], None

        err: str | None = None
        labels_by_pr: dict[int, list[str]] = {}
        try:
            proc = subprocess.run(
                ["gh", "pr", "list", "--state", "open", "--limit", "50",
                 "--json", "number,labels"],
                capture_output=True, text=True, timeout=_GH_TIMEOUT_SECONDS,
            )
        except FileNotFoundError:
            err = "gh CLI not found on PATH"
        except subprocess.TimeoutExpired:
            err = f"gh pr list timed out after {_GH_TIMEOUT_SECONDS}s"
        else:
            if proc.returncode != 0:
                err = (proc.stderr or proc.stdout).strip()[:500]
            else:
                try:
                    data = json.loads(proc.stdout or "[]")
                except json.JSONDecodeError as e:
                    err = f"gh output parse: {e}"
                else:
                    for pr in data:
                        if not isinstance(pr, dict):
                            continue
                        num = pr.get("number")
                        if not isinstance(num, int):
                            continue
                        labels_by_pr[num] = [
                            lbl.get("name", "") for lbl in (pr.get("labels") or [])
                            if isinstance(lbl, dict)
                        ]

        # Always populate the cache — even on error — so a `gh` outage
        # doesn't re-shell the CLI on every poll within the TTL window.
        # On error we cache an empty dict; callers see no labels and
        # the column-builder falls through to label-free placements.
        _pr_meta_cache = (now, labels_by_pr)
        if err:
            log.warning("api_board: pr labels fetch failed: %s", err)
        return labels_by_pr, err


# Test hook — pytest/T7 can call this between scenarios to drop the cache.
def _reset_pr_label_cache() -> None:
    global _pr_meta_cache
    with _pr_meta_lock:
        _pr_meta_cache = None


# ── Column placement (pure) ───────────────────────────────────────────────

def _column_for_task(
    task: dict,
    pr_open: bool,
    pr_merged: bool,
    pr_labels: list[str],
    sensitive: bool,
) -> str | None:
    """Map FSM status × PR state × labels → column name. None = skip.

    `pr_merged` distinguishes "PR closed-as-merged" (race with sweep-merges)
    from "PR closed-unmerged" (genuine failure). The former routes to Done;
    the latter routes to Blocked. Without this distinction, every PR briefly
    flashes through Blocked between gh-merge and the next orchestrator tick.
    """
    status = task.get("status")

    # Precedence 1: sensitive in-review with the needs-robbie sentinel
    # ALWAYS lands in Blocked, even if its PR would otherwise qualify
    # for Ready For Review or In Review.
    if status == "in_review" and sensitive and pr_open and "orch:needs-robbie" in pr_labels:
        return "blocked"

    if status == "pending":
        return "todo"
    if status == "in_progress":
        return "in_progress"
    if status == "merged":
        return "done"
    if status == "blocked":
        return "blocked"
    if status == "in_review":
        # Precedence 2: a closed-as-merged PR is the success path even if
        # the FSM hasn't flipped yet — race window between `gh pr merge`
        # and orchestrator's sweep-merges.
        if pr_merged:
            return "done"
        if not pr_open:
            # Closed-unmerged with state still in_review — defensive fallback;
            # orchestrator should have transitioned to blocked.
            return "blocked"
        has_review_sha = any(lbl.startswith("orch:review-sha:") for lbl in pr_labels)
        return "in_review" if has_review_sha else "ready_for_review"
    return None


# ── Card builder ──────────────────────────────────────────────────────────

def _agent_for_column(
    column: str, plan_slug: str, task_n: int, workers_pool: list[str],
) -> dict | None:
    # Reviewer column → Argus (hard-pinned). Done column → worker agent
    # rendered muted by frontend. Backlog/Todo have no per-task agent.
    if column in ("backlog", "todo"):
        return None
    if column == "in_review":
        return agent_for_task(plan_slug, task_n, workers_pool, "reviewer")
    return agent_for_task(plan_slug, task_n, workers_pool, "worker")


def _build_task_card(
    plan_slug_short: str,
    task_n: int,
    task: dict,
    column: str,
    pr_url: str | None,
    issue_url: str | None,
    workers_pool: list[str],
    jokes_pool: list[str],
    sensitive: bool,
    cost_usd: float | None,
    utc_date: str,
) -> dict:
    card: dict[str, Any] = {
        "plan": plan_slug_short,
        "task": task_n,
        "title": task.get("title", ""),
        "depends_on": task.get("depends_on") or [],
        "issue": task.get("issue"),
        "pr": task.get("pr"),
        "click_url": pr_url or issue_url or "",
        "status": task.get("status"),
        "sensitive": sensitive,
        "badges": [],
    }
    agent = _agent_for_column(column, plan_slug_short, task_n, workers_pool)
    if agent is not None:
        card["agent"] = agent
    if column == "done":
        card["cost_usd"] = cost_usd
    if column == "blocked":
        joke = joke_for_task(plan_slug_short, task_n, jokes_pool, utc_date)
        if joke:
            card["joke"] = joke
        # Sensitive flag takes precedence over the FSM blocked_reason
        # because the operator's UI needs to know "this needs your sign-off"
        # vs "this hit a 3x retry cap".
        if sensitive:
            card["blocked_reason"] = "needs-robbie"
        elif task.get("blocked_reason"):
            card["blocked_reason"] = task["blocked_reason"]
    return card


# ── Pure board builder ────────────────────────────────────────────────────

def build_board(
    active_states: list[tuple[str, dict]],
    archived_states: list[tuple[str, dict]],
    gh_issues: list[dict],
    gh_prs: list[dict],
    pr_labels: dict[int, list[str]],
    workers_pool: list[str],
    jokes_pool: list[str],
    *,
    cost_fn: Callable[[str, int], float] | None = None,
    utc_date: str,
) -> dict[str, list[dict]]:
    """Pure column-builder — no IO. Tests pass synthetic inputs.

    `utc_date` is required (not defaulted) so the caller is responsible
    for time. A pure function that called `datetime.now()` itself would
    re-introduce hidden state and could flip the daily joke mid-poll
    if a request straddled 00:00 UTC.
    """
    if cost_fn is None:
        cost_fn = cost_for_task

    board: dict[str, list[dict]] = {c: [] for c in _COLUMN_NAMES}

    prs_by_num = {p.get("number"): p for p in gh_prs if isinstance(p.get("number"), int)}
    issues_by_num = {i.get("number"): i for i in gh_issues if isinstance(i.get("number"), int)}

    for _path, state in [*active_states, *archived_states]:
        plan_short = _plan_slug_short(state)
        overrides = state.get("auto_merge_overrides") or {}
        for k, t in (state.get("tasks") or {}).items():
            if not isinstance(t, dict):
                continue
            try:
                task_num = int(k)
            except (TypeError, ValueError):
                continue
            sensitive = (str(k) in overrides and overrides[str(k)] is False)

            pr_num = t.get("pr")
            pr_obj = prs_by_num.get(pr_num) if isinstance(pr_num, int) else None
            pr_state = (pr_obj or {}).get("state") if pr_obj else None
            pr_merged_at = (pr_obj or {}).get("merged_at") if pr_obj else None
            pr_merged = bool(pr_obj and (pr_state == "MERGED" or pr_merged_at))
            pr_open = bool(pr_obj and pr_state == "OPEN" and not pr_merged)
            labels = pr_labels.get(pr_num, []) if isinstance(pr_num, int) else []

            column = _column_for_task(t, pr_open, pr_merged, labels, sensitive)
            if column is None:
                continue

            cost_usd: float | None = None
            if column == "done":
                try:
                    c = cost_fn(plan_short, task_num)
                    cost_usd = float(c) if c else None
                except Exception as e:  # noqa: BLE001 — defensive boundary
                    # Don't fail the entire board over one bad cost lookup,
                    # but DO log so the operator can diagnose null-cost
                    # cards from dashboard.log. Otherwise Done cards
                    # silently show "—" with no breadcrumb.
                    log.warning(
                        "api_board: cost_fn failed for %s/%s: %s: %s",
                        plan_short, task_num, type(e).__name__, e,
                    )
                    cost_usd = None

            pr_url = pr_obj.get("url") if pr_obj else None
            issue_obj = issues_by_num.get(t.get("issue")) if isinstance(t.get("issue"), int) else None
            issue_url = issue_obj.get("url") if issue_obj else None

            card = _build_task_card(
                plan_short, task_num, t, column,
                pr_url, issue_url, workers_pool, jokes_pool,
                sensitive, cost_usd, utc_date,
            )
            board[column].append(card)

    # Backlog: open GH issues with monitor:finding label
    for iss in gh_issues:
        if not isinstance(iss, dict):
            continue
        labels = iss.get("labels") or []
        if "monitor:finding" in labels:
            board["backlog"].append({
                "plan": None,
                "task": None,
                "title": iss.get("title", ""),
                "depends_on": [],
                "issue": iss.get("number"),
                "pr": None,
                "click_url": iss.get("url", ""),
                "status": "monitor",
                "sensitive": False,
                "agent": None,
                "badges": [lbl for lbl in labels if lbl != "monitor:finding"],
            })

    # Backlog: archived plans with status=blocked (one card per plan, not per task)
    for _path, state in archived_states:
        if state.get("status") == "blocked":
            board["backlog"].append({
                "plan": _plan_slug_short(state),
                "task": None,
                "title": _plan_slug_full(state),
                "depends_on": [],
                "issue": None,
                "pr": None,
                "click_url": state.get("plan_file") or "",
                "status": "blocked_plan",
                "sensitive": False,
                "agent": None,
                "badges": ["archived"],
            })

    return board


# ── Side panel composers ──────────────────────────────────────────────────

def _workers_panel(
    worktrees: list[dict],
    active_states: list[tuple[str, dict]],
    workers_pool: list[str],
) -> list[dict]:
    state_by_plan = {_plan_slug_short(st): st for _, st in active_states}
    out: list[dict] = []
    for w in worktrees:
        task_n = w.get("task_n")
        if not isinstance(task_n, int):
            continue
        branch = w.get("branch") or ""
        m = _BRANCH_PLAN_RE.search(branch)
        if not m:
            continue
        plan_short = f"PLAN-{m.group(1)}"
        title = ""
        st = state_by_plan.get(plan_short)
        if st:
            t = (st.get("tasks") or {}).get(str(task_n))
            if isinstance(t, dict):
                title = t.get("title", "")
        agent = agent_for_task(plan_short, task_n, workers_pool, "worker")
        out.append({
            "name": agent["name"],
            "avatar_seed": agent["avatar_seed"],
            "task": task_n,
            "plan": plan_short,
            "title": title,
            "worktree": w.get("path"),
            "last_log": w.get("last_log"),
            "role": "worker",
        })
    return out


def _plan_status_panel(active_states: list[tuple[str, dict]]) -> list[dict]:
    out: list[dict] = []
    for _, st in active_states:
        if st.get("status") != "in_progress":
            continue
        counts: dict[str, int] = {}
        total = 0
        for t in (st.get("tasks") or {}).values():
            if not isinstance(t, dict):
                continue
            s = t.get("status") or "pending"
            counts[s] = counts.get(s, 0) + 1
            total += 1
        out.append({
            "plan": _plan_slug_short(st),
            "slug": _plan_slug_full(st),
            "merged": counts.get("merged", 0),
            "in_progress": counts.get("in_progress", 0),
            "in_review": counts.get("in_review", 0),
            "pending": counts.get("pending", 0),
            "blocked": counts.get("blocked", 0),
            "total": total,
        })
    return out


def _classify_log_line(line: str) -> str:
    if line.startswith("=== tick "):
        return "tick"
    if line.startswith("--- phase "):
        return "phase"
    if "error:" in line:
        return "error"
    if "warning:" in line:
        return "warn"
    return "line"


def _log_tail(
    n: int = _LOG_TAIL_LINES, path: Path | None = None,
) -> tuple[list[dict], str | None]:
    """Return (lines, error). Empty list + None means "log file empty";
    empty list + error string means "read failed" — without this split
    the frontend can't distinguish a quiet orchestrator from a broken one.
    """
    p = path or _DEFAULT_LOG_PATH
    if not p.is_file():
        return [], None
    try:
        with p.open("r", encoding="utf-8", errors="replace") as f:
            raw = f.readlines()
    except OSError as e:
        msg = f"{p}: {type(e).__name__}: {e}"
        log.warning("api_board: log_tail read failed: %s", msg)
        return [], msg
    out: list[dict] = []
    for line in raw[-n:]:
        line = line.rstrip("\n")
        m = _LOG_TIME_RE.search(line)
        out.append({
            "ts": m.group(1) if m else "",
            "text": line,
            "kind": _classify_log_line(line),
        })
    return out, None


def _activity_tail(
    n: int = _EVENTS_TAIL_LINES, path: Path | None = None,
) -> tuple[list[dict], str | None]:
    p = path or _DEFAULT_EVENTS_PATH
    if not p.is_file():
        return [], None
    try:
        with p.open("r", encoding="utf-8", errors="replace") as f:
            raw = f.readlines()
    except OSError as e:
        msg = f"{p}: {type(e).__name__}: {e}"
        log.warning("api_board: activity_tail read failed: %s", msg)
        return [], msg
    out: list[dict] = []
    skipped = 0
    for line in reversed(raw):
        if len(out) >= n:
            break
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            skipped += 1
            continue
        if not isinstance(ev, dict):
            skipped += 1
            continue
        ts_iso = ev.get("ts", "")
        ts_short = ts_iso[11:19] if isinstance(ts_iso, str) and len(ts_iso) >= 19 else ts_iso
        extras = {k: v for k, v in ev.items() if k not in ("ts", "event")}
        out.append({
            "ts": ts_short,
            "kind": ev.get("event", "unknown"),
            "detail": json.dumps(extras, default=str) if extras else "",
        })
    if skipped:
        log.debug("api_board: activity_tail skipped %d malformed lines in %s", skipped, p)
    return out, None


def _github_panel(gh_issues: list[dict], gh_prs: list[dict]) -> dict:
    return {
        "issues": [
            {
                "num": i.get("number"),
                "title": i.get("title", ""),
                "labels": i.get("labels") or [],
                "url": i.get("url", ""),
            }
            for i in gh_issues[:5] if isinstance(i, dict)
        ],
        "prs": [
            {
                "num": p.get("number"),
                "title": p.get("title", ""),
                "ci_state": p.get("ci_state"),
                "url": p.get("url", ""),
            }
            for p in gh_prs[:5] if isinstance(p, dict)
        ],
    }


# ── Flask route ───────────────────────────────────────────────────────────

@bp.route("/api/board")
def board_endpoint():
    errors: list[dict] = []

    workers_pool, jokes_pool, asset_errs = _load_agents_and_jokes()
    for msg in asset_errs:
        errors.append({
            "source": "agents",
            "message": msg,
            "suggestion": "ensure static/agents.json + blocked_jokes.json exist next to api_board.py",
        })

    active_states, archived_states, state_errs = _read_state_files()
    for msg in state_errs:
        errors.append({
            "source": "state_files",
            "message": msg,
            "suggestion": "validate .claude/plans/*.state.json with `python -m json.tool`",
        })

    # api_github contract: returns (None, err) on failure, (dict, None) on success.
    gh_data, gh_err = _gh_fetch_payload()
    if gh_err:
        errors.append({
            "source": "github",
            "message": gh_err,
            "suggestion": "check `gh auth status` and network reachability",
        })
        gh_issues_raw: list[dict] = []
        gh_prs_raw: list[dict] = []
    else:
        gh_issues_raw = (gh_data or {}).get("open_issues", []) or []
        gh_prs_raw = (gh_data or {}).get("recent_prs", []) or []

    pr_labels, labels_err = _fetch_pr_labels()
    if labels_err:
        errors.append({
            "source": "github_labels",
            "message": labels_err,
            "suggestion": "ensure `gh` has repo read scope",
        })

    try:
        worktrees = _list_worktrees_for_board()
    except Exception as e:  # noqa: BLE001 — defensive boundary across module
        errors.append({
            "source": "worktrees",
            "message": f"{type(e).__name__}: {e}",
            "suggestion": "check .claude/state/active_worktrees.txt",
        })
        worktrees = []

    # Compute utc_date once per request so panels that depend on it
    # (joke rotation) all see the same value.
    utc_date = _dt.datetime.now(_dt.timezone.utc).date().isoformat()

    board = build_board(
        active_states, archived_states,
        gh_issues_raw, gh_prs_raw,
        pr_labels,
        workers_pool, jokes_pool,
        utc_date=utc_date,
    )

    try:
        cost = cost_today()
    except Exception as e:  # noqa: BLE001
        errors.append({
            "source": "cost",
            "message": f"{type(e).__name__}: {e}",
            "suggestion": "check state files have usage records",
        })
        cost = {}

    log_lines, log_err = _log_tail()
    if log_err:
        errors.append({
            "source": "log_tail",
            "message": log_err,
            "suggestion": "check .claude/state/orchestrator.log permissions",
        })

    activity_lines, activity_err = _activity_tail()
    if activity_err:
        errors.append({
            "source": "activity",
            "message": activity_err,
            "suggestion": "check .claude/state/events.jsonl permissions",
        })

    payload = {
        "as_of": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        "board": board,
        "workers": _workers_panel(worktrees, active_states, workers_pool),
        "plan_status": _plan_status_panel(active_states),
        "cost": cost,
        "log_tail": log_lines,
        "activity": activity_lines,
        "github": _github_panel(gh_issues_raw, gh_prs_raw),
        "errors": errors,
    }
    return jsonify(json_envelope(data=payload))
