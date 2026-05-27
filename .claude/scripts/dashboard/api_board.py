"""GET /api/board — unified Mission Centre payload composer.

The endpoint single-shots the entire Mission Centre view: 7-column kanban
board, Active Workers, Plan Status, cost rollup, live log tail, recent
activity, and GitHub panel. Frontend (T5) polls this every 5 s.

Architecture
------------
Pure column-builder `build_board(active_states, archived_states, gh_issues,
gh_prs, pr_labels, pr_heads, workers_pool, jokes_pool, cost_fn, utc_date)`
is the testable seam — no IO inside. The Flask route is thin glue that
loads each data source under try/except, records partial failures in an
`errors` array (which the frontend renders as per-panel "data unavailable"
banners), and hands clean inputs to `build_board`.

Agent identity (acceptance: "same (plan, task) returns the same agent
across calls"). Uses `hashlib.md5` not Python's built-in `hash()` —
the latter is PYTHONHASHSEED-randomized, so a dashboard restart would
silently reshuffle every avatar. Argus is hard-pinned to the reviewer
role per spec.

Column precedence (acceptance: "sensitive-flagged in-review tasks land
in Blocked"). The sensitive-in-review check runs before the in_review
branching, so a `auto_merge_overrides[N] == false` task with the
`orch:needs-robbie` label is routed to Blocked even if its PR would
otherwise qualify for In Review.

PR labels are fetched via `gh pr list --json number,labels,headRefOid`
with a 30 s in-memory cache. We can't piggyback the existing
api_github._fetch_payload because its PR query doesn't request labels —
and PLAN-06 T4 touches restrict edits to api_board.py.
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

# Match plan slug out of a branch like 'claude/plan-06-task-3' → '06'.
_BRANCH_PLAN_RE = re.compile(r"plan-(\d+)")
# Extract HH:MM:SS from a log line if present (for log_tail ts).
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

def _load_agents_and_jokes() -> tuple[list[str], list[str], str | None]:
    # The static dir sits next to this module. We also look in the cwd's
    # dashboard tree as a fallback so tests can stub via a tmpdir.
    candidates = [
        Path(__file__).resolve().parent / "static",
        Path(".claude/scripts/dashboard/static"),
        Path("static"),
    ]
    static_dir = next((p for p in candidates if (p / "agents.json").is_file()), None)
    if static_dir is None:
        return [], [], "static/agents.json not found"
    try:
        with (static_dir / "agents.json").open("r", encoding="utf-8") as f:
            agents = json.load(f)
        workers = [
            a["name"] for a in agents
            if isinstance(a, dict) and a.get("role") == "worker" and isinstance(a.get("name"), str)
        ]
    except (OSError, ValueError) as e:
        return [], [], f"agents.json: {type(e).__name__}: {e}"

    jokes: list[str] = []
    jokes_file = static_dir / "blocked_jokes.json"
    if jokes_file.is_file():
        try:
            with jokes_file.open("r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, list):
                jokes = [j for j in data if isinstance(j, str)]
        except (OSError, ValueError):
            jokes = []
    return workers, jokes, None


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


# ── GH PR labels + head fetcher (30 s cache) ──────────────────────────────

_pr_meta_lock = threading.Lock()
_pr_meta_cache: tuple[float, dict[int, list[str]], dict[int, str]] | None = None


def _fetch_pr_labels_and_heads() -> tuple[dict[int, list[str]], dict[int, str], str | None]:
    """Open PRs only — labels list and head SHA per PR number.

    The existing api_github cache doesn't request labels (its PR query
    is locked to a fixed --json field set we can't extend without
    touching api_github.py, which isn't in T4's touches). Separate
    cache here keyed on monotonic time; 30 s TTL matches api_github.
    """
    global _pr_meta_cache
    now = time.monotonic()
    with _pr_meta_lock:
        if _pr_meta_cache and (now - _pr_meta_cache[0]) < _PR_LABEL_CACHE_TTL_SECONDS:
            _, labels, heads = _pr_meta_cache
            return labels, heads, None
        try:
            proc = subprocess.run(
                ["gh", "pr", "list", "--state", "open", "--limit", "50",
                 "--json", "number,labels,headRefOid"],
                capture_output=True, text=True, timeout=_GH_TIMEOUT_SECONDS,
            )
        except FileNotFoundError:
            return {}, {}, "gh CLI not found on PATH"
        except subprocess.TimeoutExpired:
            return {}, {}, f"gh pr list timed out after {_GH_TIMEOUT_SECONDS}s"
        if proc.returncode != 0:
            return {}, {}, (proc.stderr or proc.stdout).strip()[:500]
        try:
            data = json.loads(proc.stdout or "[]")
        except json.JSONDecodeError as e:
            return {}, {}, f"gh output parse: {e}"
        labels_by_pr: dict[int, list[str]] = {}
        heads_by_pr: dict[int, str] = {}
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
            head = pr.get("headRefOid") or ""
            if isinstance(head, str) and head:
                heads_by_pr[num] = head
        _pr_meta_cache = (now, labels_by_pr, heads_by_pr)
        return labels_by_pr, heads_by_pr, None


# ── Column placement (pure) ───────────────────────────────────────────────

def _column_for_task(
    task: dict,
    pr_open: bool,
    pr_labels: list[str],
    sensitive: bool,
) -> str | None:
    """Map FSM status × PR state × labels → column name. None = skip."""
    status = task.get("status")

    # Precedence: sensitive in-review with the needs-robbie sentinel
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
        if not pr_open:
            # PR closed but task still in_review — orchestrator should
            # have flipped this to blocked, but be defensive.
            return "blocked"
        has_review_sha = any(lbl.startswith("orch:review-sha:") for lbl in pr_labels)
        return "in_review" if has_review_sha else "ready_for_review"
    return None


# ── Card builder ──────────────────────────────────────────────────────────

def _agent_for_column(
    column: str, plan_slug: str, task_n: int, workers_pool: list[str],
) -> dict | None:
    # Spec § "Agent role per column":
    #   Backlog/Todo     → null (issue/dep icon instead)
    #   In Progress      → worker (per-task character)
    #   Ready For Review → worker (same character — just finished)
    #   In Review        → reviewer (Argus)
    #   Blocked          → worker (per-task character + joke pill)
    #   Done             → null/worker muted (passenger)
    if column in ("backlog", "todo"):
        return None
    if column == "in_review":
        return agent_for_task(plan_slug, task_n, workers_pool, "reviewer")
    if column == "done":
        # spec calls out "muted passenger" rendering; frontend grays it.
        return agent_for_task(plan_slug, task_n, workers_pool, "worker")
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
    pr_heads: dict[int, str],
    workers_pool: list[str],
    jokes_pool: list[str],
    cost_fn: Callable[[str, int], float] | None = None,
    utc_date: str | None = None,
) -> dict[str, list[dict]]:
    """Pure column-builder — no IO. Tests pass synthetic inputs."""
    if cost_fn is None:
        cost_fn = cost_for_task
    if utc_date is None:
        utc_date = _dt.datetime.now(_dt.timezone.utc).date().isoformat()

    board: dict[str, list[dict]] = {c: [] for c in _COLUMN_NAMES}

    prs_by_num = {p.get("number"): p for p in gh_prs if isinstance(p.get("number"), int)}
    issues_by_num = {i.get("number"): i for i in gh_issues if isinstance(i.get("number"), int)}

    # Task cards from active + archived state files
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
            pr_open = bool(
                pr_obj and (pr_obj.get("state") in (None, "", "OPEN"))
                and not pr_obj.get("merged_at")
            )
            labels = pr_labels.get(pr_num, []) if isinstance(pr_num, int) else []

            column = _column_for_task(t, pr_open, labels, sensitive)
            if column is None:
                continue

            cost_usd: float | None = None
            if column == "done":
                try:
                    c = cost_fn(plan_short, task_num)
                    cost_usd = float(c) if c else None
                except Exception:
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
        counts = {"merged": 0, "in_progress": 0, "in_review": 0, "pending": 0, "blocked": 0}
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


def _log_tail(n: int = _LOG_TAIL_LINES) -> list[dict]:
    p = Path(".claude/state/orchestrator.log")
    if not p.is_file():
        return []
    try:
        with p.open("r", encoding="utf-8", errors="replace") as f:
            raw = f.readlines()
    except OSError:
        return []
    out: list[dict] = []
    for line in raw[-n:]:
        line = line.rstrip("\n")
        m = _LOG_TIME_RE.search(line)
        out.append({
            "ts": m.group(1) if m else "",
            "text": line,
            "kind": _classify_log_line(line),
        })
    return out


def _activity_tail(n: int = _EVENTS_TAIL_LINES) -> list[dict]:
    p = Path(".claude/state/events.jsonl")
    if not p.is_file():
        return []
    try:
        with p.open("r", encoding="utf-8", errors="replace") as f:
            raw = f.readlines()
    except OSError:
        return []
    out: list[dict] = []
    for line in reversed(raw):
        if len(out) >= n:
            break
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(ev, dict):
            continue
        ts_iso = ev.get("ts", "")
        ts_short = ts_iso[11:19] if isinstance(ts_iso, str) and len(ts_iso) >= 19 else ts_iso
        extras = {k: v for k, v in ev.items() if k not in ("ts", "event")}
        out.append({
            "ts": ts_short,
            "kind": ev.get("event", "unknown"),
            "detail": json.dumps(extras, default=str) if extras else "",
        })
    return out


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

    workers_pool, jokes_pool, agents_err = _load_agents_and_jokes()
    if agents_err:
        errors.append({
            "source": "agents",
            "message": agents_err,
            "suggestion": "ensure static/agents.json exists next to api_board.py",
        })

    active_states, archived_states, state_errs = _read_state_files()
    for msg in state_errs:
        errors.append({
            "source": "state_files",
            "message": msg,
            "suggestion": "validate .claude/plans/*.state.json with `python -m json.tool`",
        })

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

    pr_labels, pr_heads, labels_err = _fetch_pr_labels_and_heads()
    if labels_err:
        errors.append({
            "source": "github_labels",
            "message": labels_err,
            "suggestion": "ensure `gh` has repo read scope",
        })

    try:
        worktrees = _list_worktrees_for_board()
    except Exception as e:  # noqa: BLE001 — defensive boundary
        errors.append({
            "source": "worktrees",
            "message": f"{type(e).__name__}: {e}",
            "suggestion": "check .claude/state/active_worktrees.txt",
        })
        worktrees = []

    board = build_board(
        active_states, archived_states,
        gh_issues_raw, gh_prs_raw,
        pr_labels, pr_heads,
        workers_pool, jokes_pool,
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

    payload = {
        "as_of": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        "board": board,
        "workers": _workers_panel(worktrees, active_states, workers_pool),
        "plan_status": _plan_status_panel(active_states),
        "cost": cost,
        "log_tail": _log_tail(),
        "activity": _activity_tail(),
        "github": _github_panel(gh_issues_raw, gh_prs_raw),
        "errors": errors,
    }
    return jsonify(json_envelope(data=payload))
