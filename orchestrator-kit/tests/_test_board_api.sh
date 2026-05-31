#!/usr/bin/env bash
# Regression test for the dashboard board API: column-builder and cost-rollup
# pure functions in api_board.py / api_costs.py.
#
# Usage: bash orchestrator-kit/tests/_test_board_api.sh
#
# Exercises the 11 scenarios documented in
# orchestrator-kit/docs/SPEC-mission-centre.md "Testing" section:
#
#   1. Empty inputs → all 7 columns empty; errors empty; cost = $0
#   2. One task per FSM status → each lands in the expected column
#   3. Sensitive in-review + orch:needs-robbie → Blocked, not In Review
#   4. PR with orch:review-sha:<HEAD> → In Review (not Ready For Review)
#   5. Monitor finding issue → Backlog with click_url set to the issue
#   6. Done card with run files → cost_usd is a positive number
#   7. Done card without run files → cost_usd is null
#   8. Two tasks across two plans → both render with their plan pills
#   9. Partial GH outage → errors[] populated, other panels still render
#  10. hash(plan + task) → agent deterministic across calls
#  11. Argus is always assigned to the reviewer role
#
# Runs offline. No gh, no network, no claude. Synthetic JSON fixtures
# in mktemp tmpdirs, cleaned up via trap.
#
# Exit code: 0 = all pass, 1 = any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KIT_SCRIPTS_DIR="$KIT_ROOT/.claude/scripts"

TESTS_FAILED=0
TESTS_PASSED=0
fail() { echo "FAIL: $*" >&2; TESTS_FAILED=$((TESTS_FAILED + 1)); }
pass() { echo "PASS: $*"; TESTS_PASSED=$((TESTS_PASSED + 1)); }

TMPROOT=$(mktemp -d /tmp/_test_board_api.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT INT TERM

export KIT_SCRIPTS_DIR

run_py() {
  # Invoke an embedded python snippet; stdout/stderr stream through so
  # the operator sees diagnostics on failure. Returns Python's exit code.
  python3 -
}

# ─── Scenario 1: empty inputs ──────────────────────────────────────────────
echo "--- 1: empty inputs ---"
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" run_py <<'PY'; then
import os, sys
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
from dashboard import api_board

api_board._reset_pr_label_cache()
board = api_board.build_board(
    active_states=[],
    archived_states=[],
    gh_issues=[],
    gh_prs=[],
    pr_labels={},
    workers_pool=["Pip", "Bento", "Nova"],
    jokes_pool=["joke1"],
    cost_fn=lambda p, t: 0.0,
    utc_date="2026-05-27",
)
assert set(board.keys()) == {
    "backlog", "todo", "in_progress", "ready_for_review",
    "in_review", "blocked", "done",
}, f"unexpected columns: {board.keys()}"
for col, cards in board.items():
    assert cards == [], f"{col} should be empty, got {cards!r}"
sys.exit(0)
PY
  pass "scenario 1 (empty inputs → all 7 columns empty)"
else
  fail "scenario 1 (empty inputs)"
fi

# ─── Scenario 2: one task per FSM status ───────────────────────────────────
echo "--- 2: one task per FSM status ---"
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" run_py <<'PY'; then
import os, sys
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
from dashboard import api_board

api_board._reset_pr_label_cache()
state = {
    "plan_file": ".claude/plans/PLAN-09-fsm.md",
    "tasks": {
        "1": {"title": "pending task",     "status": "pending"},
        "2": {"title": "in-progress task", "status": "in_progress"},
        "3": {"title": "in-review task",   "status": "in_review", "pr": 301},
        "4": {"title": "in-review reviewed","status": "in_review", "pr": 302},
        "5": {"title": "merged task",      "status": "merged"},
        "6": {"title": "blocked task",     "status": "blocked"},
    },
}
gh_prs = [
    {"number": 301, "state": "OPEN", "url": "https://example/pr/301"},
    {"number": 302, "state": "OPEN", "url": "https://example/pr/302"},
]
pr_labels = {302: ["orch:review-sha:abc123"]}

board = api_board.build_board(
    active_states=[("p.json", state)],
    archived_states=[],
    gh_issues=[],
    gh_prs=gh_prs,
    pr_labels=pr_labels,
    workers_pool=["Pip", "Bento", "Nova"],
    jokes_pool=["joke1"],
    cost_fn=lambda p, t: 0.0,
    utc_date="2026-05-27",
)

def task_in(col, n):
    return any(c.get("task") == n for c in board[col])

assert task_in("todo", 1),             f"task 1 should be in todo: {board['todo']}"
assert task_in("in_progress", 2),      f"task 2 should be in in_progress: {board['in_progress']}"
assert task_in("ready_for_review", 3), f"task 3 (no review-sha) should be in ready_for_review: {board['ready_for_review']}"
assert task_in("in_review", 4),        f"task 4 (review-sha present) should be in in_review: {board['in_review']}"
assert task_in("done", 5),             f"task 5 should be in done: {board['done']}"
assert task_in("blocked", 6),          f"task 6 should be in blocked: {board['blocked']}"

# And nothing else snuck into the wrong column.
total = sum(len(v) for v in board.values())
assert total == 6, f"expected 6 cards across all columns, got {total}: {board}"
sys.exit(0)
PY
  pass "scenario 2 (one task per FSM status)"
else
  fail "scenario 2 (one task per FSM status)"
fi

# ─── Scenario 3: sensitive in-review + orch:needs-robbie → Blocked ─────────
echo "--- 3: sensitive in-review with needs-robbie ---"
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" run_py <<'PY'; then
import os, sys
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
from dashboard import api_board

api_board._reset_pr_label_cache()
state = {
    "plan_file": ".claude/plans/PLAN-09-sens.md",
    "auto_merge_overrides": {"3": False},
    "tasks": {
        "3": {"title": "iam change", "status": "in_review", "pr": 401},
    },
}
gh_prs = [{"number": 401, "state": "OPEN", "url": "https://example/pr/401"}]
# Even with the review-sha label that would normally route to in_review,
# the sensitive flag + needs-robbie label MUST send the card to Blocked.
pr_labels = {401: ["orch:needs-robbie", "orch:review-sha:abc"]}

board = api_board.build_board(
    active_states=[("p.json", state)],
    archived_states=[],
    gh_issues=[],
    gh_prs=gh_prs,
    pr_labels=pr_labels,
    workers_pool=["Pip", "Bento"],
    jokes_pool=["i tried", "send a human"],
    cost_fn=lambda p, t: 0.0,
    utc_date="2026-05-27",
)

assert len(board["blocked"]) == 1, f"sensitive in-review should land in blocked: {board}"
assert board["in_review"] == [], f"in_review should be empty: {board['in_review']}"
assert board["ready_for_review"] == [], f"ready_for_review should be empty: {board['ready_for_review']}"

card = board["blocked"][0]
assert card["task"] == 3
assert card["sensitive"] is True
assert card.get("blocked_reason") == "needs-robbie", f"blocked_reason should be needs-robbie: {card}"
assert isinstance(card.get("joke"), str) and card["joke"], "blocked card should carry a joke"
sys.exit(0)
PY
  pass "scenario 3 (sensitive in-review → Blocked with needs-robbie)"
else
  fail "scenario 3 (sensitive in-review → Blocked)"
fi

# ─── Scenario 4: PR with review-sha label lands in In Review ──────────────
# Per the implementation note in PLAN-06 T7 spec: the current _column_for_task
# simplifies "iterator running" into "any orch:review-sha:* label present →
# in_review". The iter rN/5 badge is a frontend concern (T5). Here we assert
# the contract this codebase implements: review-sha → in_review regardless
# of orch:review-blocked.
echo "--- 4: iterator-running heuristic (review-sha → In Review) ---"
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" run_py <<'PY'; then
import os, sys
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
from dashboard import api_board

api_board._reset_pr_label_cache()
state = {
    "plan_file": ".claude/plans/PLAN-09-iter.md",
    "tasks": {
        "7": {"title": "review-blocked task", "status": "in_review", "pr": 501},
    },
}
gh_prs = [{"number": 501, "state": "OPEN", "url": "https://example/pr/501"}]
pr_labels = {501: ["orch:review-sha:deadbeef", "orch:review-blocked"]}

board = api_board.build_board(
    active_states=[("p.json", state)],
    archived_states=[],
    gh_issues=[],
    gh_prs=gh_prs,
    pr_labels=pr_labels,
    workers_pool=["Pip", "Bento"],
    jokes_pool=["joke"],
    cost_fn=lambda p, t: 0.0,
    utc_date="2026-05-27",
)

assert len(board["in_review"]) == 1, f"review-sha task should be in in_review: {board}"
assert board["ready_for_review"] == [], f"ready_for_review should be empty: {board}"
card = board["in_review"][0]
assert card["task"] == 7
assert card.get("agent", {}).get("role") == "reviewer", \
    f"in_review card should carry reviewer agent: {card}"
sys.exit(0)
PY
  pass "scenario 4 (review-sha → In Review)"
else
  fail "scenario 4 (review-sha → In Review)"
fi

# ─── Scenario 5: monitor finding issue → Backlog ───────────────────────────
echo "--- 5: monitor finding → Backlog with click_url ---"
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" run_py <<'PY'; then
import os, sys
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
from dashboard import api_board

api_board._reset_pr_label_cache()
gh_issues = [{
    "number": 77,
    "title": "monitor: repeated worker_failed_3x on T2",
    "labels": ["monitor:finding", "needs-triage"],
    "url": "https://example/issues/77",
}]

board = api_board.build_board(
    active_states=[],
    archived_states=[],
    gh_issues=gh_issues,
    gh_prs=[],
    pr_labels={},
    workers_pool=["Pip"],
    jokes_pool=["j"],
    cost_fn=lambda p, t: 0.0,
    utc_date="2026-05-27",
)

assert len(board["backlog"]) == 1, f"backlog should hold the monitor finding: {board}"
card = board["backlog"][0]
assert card["issue"] == 77
assert card["click_url"] == "https://example/issues/77", \
    f"click_url should point to the issue: {card}"
assert card["status"] == "monitor"
# Column exclusivity — the monitor card must not have leaked anywhere else.
total = sum(len(v) for v in board.values())
assert total == 1, f"only the monitor card should exist; got {total} across {board}"
sys.exit(0)
PY
  pass "scenario 5 (monitor finding → Backlog)"
else
  fail "scenario 5 (monitor finding → Backlog)"
fi

# ─── Scenario 6: Done card with run files → positive cost ──────────────────
# cost_for_task reads .claude/plans/*.state.json with tasks[N].usage.runs[].
# We chdir into a tmpdir, drop a synthetic state file, and assert the rollup
# returns the expected positive number. This also exercises the per-state
# mtime cache through cost_for_task.
echo "--- 6: Done card with run files → positive cost ---"
SCEN6_DIR="$TMPROOT/scen6"
mkdir -p "$SCEN6_DIR/.claude/plans"
cat > "$SCEN6_DIR/.claude/plans/PLAN-09-cost.state.json" <<'JSON'
{
  "plan_file": ".claude/plans/PLAN-09-cost.md",
  "total_tasks": 1,
  "status": "in_progress",
  "tasks": {
    "5": {
      "title": "done w/ runs",
      "status": "merged",
      "usage": {
        "runs": [
          {"kind": "worker",   "cost_usd": 0.30, "run_at": "2026-05-27T01:00:00Z"},
          {"kind": "iterator", "cost_usd": 0.10, "run_at": "2026-05-27T02:00:00Z"},
          {"kind": "reviewer", "cost_usd": 0.05, "run_at": "2026-05-27T03:00:00Z"}
        ]
      }
    }
  }
}
JSON
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" SCEN6_DIR="$SCEN6_DIR" run_py <<'PY'; then
import os, sys
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
os.chdir(os.environ["SCEN6_DIR"])
from dashboard import api_board, api_costs

# Drop any cache from prior scenarios so we read fresh from the tmpdir.
api_costs._state_cache.clear()
api_board._reset_pr_label_cache()

# Direct cost_for_task assertion.
direct = api_costs.cost_for_task("PLAN-09", 5)
assert abs(direct - 0.45) < 0.0001, f"cost_for_task should sum all runs: got {direct}"

# And the board should embed the same number in the Done card's cost_usd.
state = {
    "plan_file": ".claude/plans/PLAN-09-cost.md",
    "tasks": {
        "5": {"title": "done w/ runs", "status": "merged"},
    },
}
board = api_board.build_board(
    active_states=[("p.json", state)],
    archived_states=[],
    gh_issues=[],
    gh_prs=[],
    pr_labels={},
    workers_pool=["Pip"],
    jokes_pool=["j"],
    cost_fn=api_costs.cost_for_task,
    utc_date="2026-05-27",
)
assert len(board["done"]) == 1, f"done column should have 1 card: {board}"
card = board["done"][0]
assert card.get("cost_usd") is not None, f"cost_usd should be present on Done: {card}"
assert card["cost_usd"] > 0.0, f"cost_usd should be positive: {card}"
assert abs(card["cost_usd"] - 0.45) < 0.0001, f"cost_usd should equal direct rollup: {card}"
total = sum(len(v) for v in board.values())
assert total == 1, f"only the Done card should exist; got {total} across {board}"
sys.exit(0)
PY
  pass "scenario 6 (Done card with run files → positive cost summed across retries)"
else
  fail "scenario 6 (Done card with run files)"
fi

# ─── Scenario 7: Done card without run files → cost_usd is null ────────────
echo "--- 7: Done card without run files → cost_usd null ---"
SCEN7_DIR="$TMPROOT/scen7"
mkdir -p "$SCEN7_DIR/.claude/plans"
# State file with no usage.runs block.
cat > "$SCEN7_DIR/.claude/plans/PLAN-09-nocost.state.json" <<'JSON'
{
  "plan_file": ".claude/plans/PLAN-09-nocost.md",
  "total_tasks": 1,
  "status": "in_progress",
  "tasks": {
    "8": {"title": "done w/o runs", "status": "merged"}
  }
}
JSON
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" SCEN7_DIR="$SCEN7_DIR" run_py <<'PY'; then
import os, sys
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
os.chdir(os.environ["SCEN7_DIR"])
from dashboard import api_board, api_costs

api_costs._state_cache.clear()
api_board._reset_pr_label_cache()

assert api_costs.cost_for_task("PLAN-09", 8) == 0.0, \
    "cost_for_task should be 0.0 when no usage data exists"

state = {
    "plan_file": ".claude/plans/PLAN-09-nocost.md",
    "tasks": {"8": {"title": "done w/o runs", "status": "merged"}},
}
board = api_board.build_board(
    active_states=[("p.json", state)],
    archived_states=[],
    gh_issues=[],
    gh_prs=[],
    pr_labels={},
    workers_pool=["Pip"],
    jokes_pool=["j"],
    cost_fn=api_costs.cost_for_task,
    utc_date="2026-05-27",
)
assert len(board["done"]) == 1, f"done column should have 1 card: {board}"
card = board["done"][0]
# build_board normalises 0/None to None on the Done card (the frontend
# renders that as "—").
assert card.get("cost_usd") is None, \
    f"cost_usd should be None when there's no usage data: {card}"
total = sum(len(v) for v in board.values())
assert total == 1, f"only the Done card should exist; got {total} across {board}"
sys.exit(0)
PY
  pass "scenario 7 (Done card without run files → cost_usd null)"
else
  fail "scenario 7 (Done card without run files)"
fi

# ─── Scenario 8: two plans rendered with their respective pills ────────────
echo "--- 8: two tasks across two plans ---"
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" run_py <<'PY'; then
import os, sys
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
from dashboard import api_board

api_board._reset_pr_label_cache()
state_a = {
    "plan_file": ".claude/plans/PLAN-05-aws.md",
    "tasks": {"1": {"title": "task A", "status": "in_progress"}},
}
state_b = {
    "plan_file": ".claude/plans/PLAN-06-mission.md",
    "tasks": {"1": {"title": "task B", "status": "in_progress"}},
}

board = api_board.build_board(
    active_states=[("a.json", state_a), ("b.json", state_b)],
    archived_states=[],
    gh_issues=[],
    gh_prs=[],
    pr_labels={},
    workers_pool=["Pip", "Bento", "Nova", "Echo"],
    jokes_pool=["j"],
    cost_fn=lambda p, t: 0.0,
    utc_date="2026-05-27",
)

plans = sorted(c["plan"] for c in board["in_progress"])
assert plans == ["PLAN-05", "PLAN-06"], \
    f"both plan pills should appear in in_progress column: {plans}"
total = sum(len(v) for v in board.values())
assert total == 2, f"exactly 2 cards expected (one per plan); got {total} across {board}"
sys.exit(0)
PY
  pass "scenario 8 (two plans render with their respective pills)"
else
  fail "scenario 8 (two plans)"
fi

# ─── Scenario 9: partial GH outage → errors[] populated, board still renders
# Test the Flask route handler (board_endpoint) because the errors[] array is
# its responsibility, not build_board's. We monkeypatch _gh_fetch_payload to
# return a stub error, register the blueprint on a fresh Flask app, and
# inspect the JSON response.
echo "--- 9: partial GH outage → errors[] populated ---"
SCEN9_DIR="$TMPROOT/scen9"
mkdir -p "$SCEN9_DIR/.claude/plans"
# Drop a minimal state file so other panels have something to render.
cat > "$SCEN9_DIR/.claude/plans/PLAN-09-gh.state.json" <<'JSON'
{
  "plan_file": ".claude/plans/PLAN-09-gh.md",
  "total_tasks": 1,
  "status": "in_progress",
  "tasks": {
    "1": {"title": "lonely todo", "status": "pending"}
  }
}
JSON
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" SCEN9_DIR="$SCEN9_DIR" run_py <<'PY'; then
import os, sys, json
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
os.chdir(os.environ["SCEN9_DIR"])

from flask import Flask
from dashboard import api_board, api_costs

api_costs._state_cache.clear()
api_board._reset_pr_label_cache()

# Stub the two IO seams the route handler hits via module-level imports.
api_board._gh_fetch_payload = lambda: (None, "stubbed gh outage")
api_board._list_worktrees_for_board = lambda: []
# Don't let the real gh-labels subprocess fire either.
api_board._fetch_pr_labels = lambda: ({}, None)

app = Flask(__name__)
app.register_blueprint(api_board.bp)
client = app.test_client()

resp = client.get("/api/board")
assert resp.status_code == 200, f"status: {resp.status_code} body: {resp.data}"
envelope = resp.get_json()
payload = envelope["data"]

# The github error must surface in errors[] with the documented shape.
github_errs = [e for e in payload["errors"] if e.get("source") == "github"]
assert github_errs, f"expected a github error entry: {payload['errors']}"
assert "stubbed gh outage" in github_errs[0].get("message", ""), \
    f"error message should carry the stub text: {github_errs[0]}"

# Other panels still render — the lonely todo card from the state file
# must be present in the board.
assert len(payload["board"]["todo"]) == 1, \
    f"todo column should still render despite gh outage: {payload['board']['todo']}"
assert payload["board"]["todo"][0]["title"] == "lonely todo"
sys.exit(0)
PY
  pass "scenario 9 (partial GH outage → errors[] populated, other panels render)"
else
  fail "scenario 9 (partial GH outage)"
fi

# ─── Scenario 10: hash(plan + task) → agent deterministic ──────────────────
echo "--- 10: agent assignment deterministic ---"
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" run_py <<'PY'; then
import os, sys
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
from dashboard import api_board

pool = ["Pip", "Bento", "Nova", "Echo", "Glitch", "Bug", "Mochi", "Cosmo",
        "Pixel", "Spark", "Tofu", "Otter", "Pepper", "Patch", "Loop", "Snap",
        "Tweak", "Zog", "Boop", "Comet"]

# Repeated calls with the same (plan, task) must produce the same name.
first = api_board.agent_for_task("PLAN-05", 3, pool, "worker")
for _ in range(50):
    again = api_board.agent_for_task("PLAN-05", 3, pool, "worker")
    assert again == first, f"agent assignment drifted: {again} != {first}"

# Pinned name — load-bearing. The implementation's docstring picks md5 over
# Python's built-in hash() because hash() is PYTHONHASHSEED-randomized and
# would silently break determinism across dashboard restarts. Within a
# single process both look stable, so a same-process "repeated calls match"
# check above would NOT catch a md5→hash() swap. Pinning a known expected
# name does: change the hash function and "Pixel" will become something else.
assert first["name"] == "Pixel", (
    f"agent_for_task('PLAN-05', 3) must be 'Pixel' under the pinned md5 "
    f"hash. If this fails, _stable_hash() likely got replaced by hash() — "
    f"see the docstring in api_board.py. Got: {first}"
)

# Distribution sanity — a buggy function that always returned pool[0]
# would satisfy issubset() above. Require some variety across 20 tasks.
names = {api_board.agent_for_task("PLAN-05", t, pool, "worker")["name"]
         for t in range(20)}
assert names.issubset(set(pool)), f"agent names must be drawn from pool: {names - set(pool)}"
assert len(names) >= 5, (
    f"agent_for_task should distribute across the pool, not collapse to one "
    f"name. Got only {len(names)} distinct names across 20 tasks: {names}"
)

# And iterator role uses the same per-task character as worker role.
worker_name = api_board.agent_for_task("PLAN-06", 9, pool, "worker")["name"]
iter_name   = api_board.agent_for_task("PLAN-06", 9, pool, "iterator")["name"]
assert worker_name == iter_name, \
    f"iterator should inherit the worker's per-task agent: worker={worker_name} iter={iter_name}"
sys.exit(0)
PY
  pass "scenario 10 (hash(plan+task) → agent is deterministic)"
else
  fail "scenario 10 (agent deterministic)"
fi

# ─── Scenario 11: Argus assignment for the reviewer role ───────────────────
echo "--- 11: reviewer role → Argus ---"
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" run_py <<'PY'; then
import os, sys
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
from dashboard import api_board

pool = ["Pip", "Bento", "Nova"]

# Argus is hard-pinned regardless of (plan, task).
for plan in ("PLAN-05", "PLAN-06", "PLAN-99-very-long"):
    for task in (0, 1, 7, 42, 1000):
        agent = api_board.agent_for_task(plan, task, pool, "reviewer")
        assert agent["name"] == "Argus", f"reviewer must be Argus: got {agent} for {plan}/{task}"
        assert agent["avatar_seed"] == "Argus"
        assert agent["role"] == "reviewer"

# Empty pool must not break the reviewer pin (Argus is independent of pool).
agent = api_board.agent_for_task("PLAN-99", 1, [], "reviewer")
assert agent["name"] == "Argus", f"reviewer pin must hold with empty pool: {agent}"
sys.exit(0)
PY
  pass "scenario 11 (reviewer role always returns Argus)"
else
  fail "scenario 11 (Argus assignment)"
fi

# ─── Scenario 12: in_review with pr_obj None must not fall to Blocked ─────
# Regression for PLAN-07 T1: when `gh pr list` truncates (default --limit
# was too low) or lags behind PR creation, an in_review task whose pr
# number isn't in gh_prs used to slip through the defensive "pr_open is
# False → blocked" branch in _column_for_task. The new
# _column_when_pr_missing helper routes on task.status alone instead.
echo "--- 12: in_review with pr_obj None → in_review / ready_for_review ---"
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" run_py <<'PY'; then
import os, sys
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
from dashboard import api_board

api_board._reset_pr_label_cache()
state = {
    "plan_file": ".claude/plans/PLAN-09-trunc.md",
    "tasks": {
        # PR 9001 lives in the task row but is missing from gh_prs below —
        # simulates gh pr list truncation or a slow gh sync.
        "1": {"title": "no-label in-review",   "status": "in_review", "pr": 9001},
        # PR 9002 also missing from gh_prs but its labels are populated
        # via the independent pr_labels fetch (which works even when the
        # PR doesn't appear in gh_prs).
        "2": {"title": "review-sha in-review", "status": "in_review", "pr": 9002},
    },
}
# Deliberately empty: simulates gh pr list returning a truncated page
# that excludes both PRs.
gh_prs = []
pr_labels = {9002: ["orch:review-sha:cafef00d"]}

board = api_board.build_board(
    active_states=[("p.json", state)],
    archived_states=[],
    gh_issues=[],
    gh_prs=gh_prs,
    pr_labels=pr_labels,
    workers_pool=["Pip", "Bento"],
    jokes_pool=["j"],
    cost_fn=lambda p, t: 0.0,
    utc_date="2026-05-27",
)

def task_in(col, n):
    return any(c.get("task") == n for c in board[col])

assert board["blocked"] == [], (
    f"in_review tasks with missing pr_obj must NOT fall to Blocked: "
    f"{board['blocked']}"
)
assert task_in("ready_for_review", 1), (
    f"task 1 (no labels) should land in ready_for_review: {board}"
)
assert task_in("in_review", 2), (
    f"task 2 (review-sha label present) should land in in_review: {board}"
)
total = sum(len(v) for v in board.values())
assert total == 2, f"expected exactly 2 cards across all columns, got {total}: {board}"
sys.exit(0)
PY
  pass "scenario 12 (in_review with pr_obj None routes by status, not Blocked)"
else
  fail "scenario 12 (in_review with pr_obj None)"
fi

# ─── Scenario 13: pr-label cache surfaces gh err on every TTL-window poll ─
# Regression for PLAN-07 T2: when `gh pr list --json number,labels` fails,
# the prior implementation cached only (timestamp, labels_dict) and dropped
# `err` on cache hits — so the `errors[]` channel surfaced the outage on
# the first poll and went silent for the next 30 s, even though the
# fetcher kept returning an empty labels dict. Operators looking at the
# dashboard saw the warning banner clear while sensitive in-review tasks
# could still migrate out of Blocked due to absent labels. The fix widens
# the cache to (timestamp, labels_dict, err) and returns the cached err
# on every hit until the next successful refetch clears it.
echo "--- 13: pr-label cache returns cached err on every poll within TTL ---"
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" run_py <<'PY'; then
import os, sys, subprocess
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
from dashboard import api_board

# Start from a clean cache so the first poll forces a fetch.
api_board._reset_pr_label_cache()

# Fake subprocess.run so we can deterministically toggle gh success/failure.
# The fetcher only ever calls subprocess.run with `gh pr list ...` here; an
# argv-shape check keeps the stub from silently shadowing unrelated calls if
# the fetcher is ever refactored.
class FakeProc:
    def __init__(self, returncode, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr

_real_run = subprocess.run
_call_log = []
_mode = {"value": "fail"}  # toggle between "fail" and "ok"

def fake_run(cmd, **kwargs):
    if not (isinstance(cmd, list) and cmd[:2] == ["gh", "pr"]):
        return _real_run(cmd, **kwargs)
    _call_log.append(_mode["value"])
    if _mode["value"] == "fail":
        return FakeProc(returncode=1, stderr="gh: API rate limit exceeded\n")
    return FakeProc(
        returncode=0,
        stdout='[{"number": 7777, "labels": [{"name": "orch:needs-robbie"}]}]',
    )

api_board.subprocess.run = fake_run
try:
    # Poll 1 — gh fails; err is populated and cached.
    labels1, err1 = api_board._fetch_pr_labels()
    assert labels1 == {}, f"poll 1: labels should be empty on failure: {labels1!r}"
    assert err1 and "rate limit" in err1, f"poll 1: err should carry gh stderr: {err1!r}"
    assert _call_log == ["fail"], f"poll 1 should have shelled gh once: {_call_log}"

    # Poll 2 — within the 30 s TTL. MUST return the cached err (not None)
    # without re-shelling gh. This is the core regression: the prior
    # implementation returned (cached_labels, None) here.
    labels2, err2 = api_board._fetch_pr_labels()
    assert labels2 == {}, f"poll 2: labels should still be empty: {labels2!r}"
    assert err2 == err1, (
        f"poll 2: cache hit MUST replay the cached err on every TTL-window "
        f"poll, not just the first. Got err2={err2!r}, expected {err1!r}"
    )
    assert _call_log == ["fail"], (
        f"poll 2: cache hit must NOT re-shell gh within the TTL: {_call_log}"
    )

    # Poll 3 — force a cache reset and let gh succeed. The cached err must
    # clear back to None on a successful refetch (acceptance #3).
    api_board._reset_pr_label_cache()
    _mode["value"] = "ok"
    labels3, err3 = api_board._fetch_pr_labels()
    assert err3 is None, f"poll 3: successful refetch must clear cached err: {err3!r}"
    assert labels3 == {7777: ["orch:needs-robbie"]}, (
        f"poll 3: labels should reflect the stubbed gh response: {labels3!r}"
    )
    assert _call_log == ["fail", "ok"], (
        f"poll 3 should have shelled gh again after reset: {_call_log}"
    )

    # And a cache hit after the successful refetch must keep err=None
    # (closing the loop — the err clear is durable, not transient).
    labels4, err4 = api_board._fetch_pr_labels()
    assert err4 is None, f"poll 4: cache hit after success must still carry err=None: {err4!r}"
    assert labels4 == labels3, f"poll 4: labels should match cached success: {labels4!r}"
    assert _call_log == ["fail", "ok"], (
        f"poll 4: cache hit must NOT re-shell gh: {_call_log}"
    )
finally:
    api_board.subprocess.run = _real_run
    api_board._reset_pr_label_cache()
sys.exit(0)
PY
  pass "scenario 13 (pr-label cache replays err on every TTL poll, clears on refetch)"
else
  fail "scenario 13 (pr-label cache err replay)"
fi

# ─── Scenario 14: truncated state.json surfaces via api_costs.load_errors ──
# Regression for PLAN-07 T3: when a state file is unreadable / truncated /
# malformed, _load_state used to swallow the exception and return {} with
# zero diagnostic — the cost + token panels silently zero'd out. The fix
# logs a warning AND appends to a module-level error list that the
# /api/board composer folds into errors[] with source="api_costs". This
# test exercises the api_costs layer (cost_today fallback + load_errors)
# AND the api_board layer (errors[] surfacing).
echo "--- 14: truncated state.json surfaces via load_errors + /api/board ---"
SCEN14_DIR="$TMPROOT/scen14"
mkdir -p "$SCEN14_DIR/.claude/plans"
# Truncated state file: JSON object with the closing brace removed.
# json.load will raise ValueError (json.JSONDecodeError); _load_state
# must log + record and return {}.
cat > "$SCEN14_DIR/.claude/plans/PLAN-09-broken.state.json" <<'JSON'
{
  "plan_file": ".claude/plans/PLAN-09-broken.md",
  "total_tasks": 1,
  "status": "in_progress",
  "tasks": {
    "1": {
      "title": "broken state",
      "status": "merged",
      "usage": {
        "runs": [
          {"kind": "worker", "cost_usd": 0.10, "run_at": "2026-05-27T01:00:00Z"}
        ]
      }
    }
JSON
# Also drop a valid state file so cost_today has at least one path to walk
# successfully — the test must show the bad file is named in load_errors
# while the good file still aggregates normally.
cat > "$SCEN14_DIR/.claude/plans/PLAN-09-good.state.json" <<'JSON'
{
  "plan_file": ".claude/plans/PLAN-09-good.md",
  "total_tasks": 1,
  "status": "in_progress",
  "tasks": {
    "2": {
      "title": "valid state",
      "status": "merged",
      "usage": {
        "runs": [
          {"kind": "worker", "cost_usd": 0.20, "run_at": "1999-01-01T01:00:00Z"}
        ]
      }
    }
  }
}
JSON
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" SCEN14_DIR="$SCEN14_DIR" run_py <<'PY'; then
import os, sys, json
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
os.chdir(os.environ["SCEN14_DIR"])

from flask import Flask
from dashboard import api_board, api_costs

# Drop caches so each assertion reads the tmpdir from scratch.
api_costs._state_cache.clear()
api_costs._reset_load_errors()
api_board._reset_pr_label_cache()

# ── Layer 1: api_costs.cost_today fallback + load_errors ─────────────────
result = api_costs.cost_today()
# The good file's run is dated 1999 (well outside today), so today_usd
# should be 0.0. But the function must NOT raise on the truncated file —
# it returns a dict (possibly with today_usd = 0.0) rather than crashing.
# `cost_today` returns {} only when NO usage data exists at all; the good
# file has usage so the call returns a populated dict.
assert isinstance(result, dict), f"cost_today must return a dict (fallback), got {type(result).__name__}"
assert result.get("today_usd", 0.0) == 0.0, (
    f"today_usd should be 0.0 (good file's run is dated 1999): {result}"
)

errs = api_costs.load_errors()
assert errs, f"load_errors must be non-empty after a truncated state file load: {errs!r}"
broken_path = ".claude/plans/PLAN-09-broken.state.json"
matching = [e for e in errs if broken_path in e]
assert matching, (
    f"load_errors must name the bad path {broken_path!r}: {errs!r}"
)
# Exception type should appear in the message — the spec calls for naming
# the path AND the exception type so the operator can distinguish a
# permissions error from a JSON parse error from a missing file.
assert any("Error" in e or "Exception" in e for e in matching), (
    f"load_errors entry should name the exception type: {matching!r}"
)

# ── Layer 2: load_errors is a copy, not the live buffer ──────────────────
errs.append("synthetic pollution")
assert "synthetic pollution" not in api_costs.load_errors(), (
    "load_errors() must return a copy; mutating the result must not leak "
    "back into the live buffer"
)

# ── Layer 3: reset semantics — re-calling cost_today wipes prior errors ──
# A subsequent cost_today() call with a fresh _state_cache should reset
# the buffer at the start, then repopulate with the bad file's error
# (same path, same exception). The bad file should appear EXACTLY once,
# not accumulated from the prior call.
api_costs._state_cache.clear()
api_costs.cost_today()
errs_after = api_costs.load_errors()
bad_path_count = sum(1 for e in errs_after if broken_path in e)
assert bad_path_count == 1, (
    f"reset semantics broken: bad path should appear exactly once after a "
    f"fresh cost_today() call (reset + 1 repopulate), got {bad_path_count} "
    f"in {errs_after!r}"
)

# ── Layer 4: api_board /api/board surfaces api_costs errors in errors[] ──
# Stub the gh/worker IO seams so the route handler reaches the cost layer
# and we can inspect the JSON envelope cleanly.
api_board._gh_fetch_payload = lambda: ({"open_issues": [], "recent_prs": []}, None)
api_board._list_worktrees_for_board = lambda: []
api_board._fetch_pr_labels = lambda: ({}, None)
api_costs._state_cache.clear()
api_costs._reset_load_errors()
api_board._reset_pr_label_cache()

app = Flask(__name__)
app.register_blueprint(api_board.bp)
client = app.test_client()

resp = client.get("/api/board")
assert resp.status_code == 200, f"status: {resp.status_code} body: {resp.data}"
envelope = resp.get_json()
payload = envelope["data"]

api_costs_errs = [e for e in payload["errors"] if e.get("source") == "api_costs"]
assert api_costs_errs, (
    f"/api/board errors[] must include source='api_costs' entries when a "
    f"state file fails to load: {payload['errors']!r}"
)
assert any(broken_path in e.get("message", "") for e in api_costs_errs), (
    f"at least one api_costs error must name {broken_path!r}: {api_costs_errs!r}"
)
sys.exit(0)
PY
  pass "scenario 14 (truncated state.json surfaces via load_errors + /api/board errors[])"
else
  fail "scenario 14 (truncated state.json surfaces via load_errors)"
fi

# ─── Scenario 15: /api/costs happy path → 200 with empty errors[] ────────
# Regression for PLAN-07 T4 acceptance #5: the route handler returns the
# documented schema (today_tokens, today_cost, per_task, errors) with an
# empty errors[] when every state file loads cleanly.
echo "--- 15: /api/costs happy path → 200, errors[] empty ---"
SCEN15_DIR="$TMPROOT/scen15"
mkdir -p "$SCEN15_DIR/.claude/plans"
cat > "$SCEN15_DIR/.claude/plans/PLAN-15-happy.state.json" <<'JSON'
{
  "plan_file": ".claude/plans/PLAN-15-happy.md",
  "total_tasks": 1,
  "status": "in_progress",
  "tasks": {
    "1": {
      "title": "happy task",
      "status": "merged",
      "usage": {
        "runs": [
          {"kind": "worker", "cost_usd": 0.50, "run_at": "2026-05-27T01:00:00Z"}
        ]
      }
    }
  }
}
JSON
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" SCEN15_DIR="$SCEN15_DIR" run_py <<'PY'; then
import os, sys
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
os.chdir(os.environ["SCEN15_DIR"])

from flask import Flask
from dashboard import api_costs

api_costs._state_cache.clear()
api_costs._reset_load_errors()

app = Flask(__name__)
app.register_blueprint(api_costs.bp)
client = app.test_client()

resp = client.get("/api/costs")
assert resp.status_code == 200, f"status: {resp.status_code} body: {resp.data}"
envelope = resp.get_json()
assert envelope.get("error") is None, f"happy path must not set envelope.error: {envelope}"
payload = envelope["data"]

# Documented schema: today_tokens, today_cost, per_task, errors must all
# be present so the frontend can render without optional-key gymnastics.
for k in ("today_tokens", "today_cost", "per_task", "errors"):
    assert k in payload, f"payload missing key {k!r}: {payload}"

assert payload["errors"] == [], (
    f"happy path must produce empty errors[]: {payload['errors']}"
)
# The happy state file should appear in per_task under its plan_file slug.
assert "PLAN-15-happy" in payload["per_task"], (
    f"per_task should contain the loaded plan: {payload['per_task']}"
)
plan_entry = payload["per_task"]["PLAN-15-happy"]
assert "1" in plan_entry, f"task 1 should be in plan entry: {plan_entry}"
assert plan_entry["1"]["cost_usd"] == 0.5, (
    f"cost_usd should reflect the run: {plan_entry['1']}"
)
sys.exit(0)
PY
  pass "scenario 15 (/api/costs happy path → 200 with empty errors[])"
else
  fail "scenario 15 (/api/costs happy path)"
fi

# ─── Scenario 16: per-file catch — KeyError on one file does NOT nuke payload
# Regression for PLAN-07 T4 acceptance #6: a malformed task dict that
# raises KeyError inside the per_task loop must be scoped to that single
# state file. The route returns 200 with errors[] naming the bad path,
# and the OTHER (good) state file's per_task entries are still present.
#
# Trigger mechanism: monkey-patch cost_for_task to raise KeyError when
# called with the bad plan's short slug. The natural code paths use
# .get() throughout and don't raise KeyError on schema drift, so the
# test stubs the helper to exercise the new per-file outer except block.
# Functionally identical to a hypothetical future schema where some
# helper does dict-key access and a missing key surfaces as KeyError.
echo "--- 16: /api/costs per-file catch isolates one bad state file ---"
SCEN16_DIR="$TMPROOT/scen16"
mkdir -p "$SCEN16_DIR/.claude/plans"
cat > "$SCEN16_DIR/.claude/plans/PLAN-16-good.state.json" <<'JSON'
{
  "plan_file": ".claude/plans/PLAN-16-good.md",
  "total_tasks": 1,
  "status": "in_progress",
  "tasks": {
    "1": {
      "title": "good task",
      "status": "merged",
      "usage": {
        "runs": [
          {"kind": "worker", "cost_usd": 0.20, "run_at": "2026-05-27T01:00:00Z"}
        ]
      }
    }
  }
}
JSON
cat > "$SCEN16_DIR/.claude/plans/PLAN-17-bad.state.json" <<'JSON'
{
  "plan_file": ".claude/plans/PLAN-17-bad.md",
  "total_tasks": 1,
  "status": "in_progress",
  "tasks": {
    "1": {
      "title": "task whose rollup raises KeyError",
      "status": "merged",
      "usage": {
        "runs": [
          {"kind": "worker", "cost_usd": 0.10, "run_at": "2026-05-27T01:00:00Z"}
        ]
      }
    }
  }
}
JSON
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" SCEN16_DIR="$SCEN16_DIR" run_py <<'PY'; then
import os, sys
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
os.chdir(os.environ["SCEN16_DIR"])

from flask import Flask
from dashboard import api_costs

api_costs._state_cache.clear()
api_costs._reset_load_errors()

# Stub cost_for_task: raise KeyError for the bad plan, defer to the real
# implementation for the good plan. The route imports cost_for_task by
# name into its module scope, so patching api_costs.cost_for_task changes
# what the route sees on the next call.
_real_cost_for_task = api_costs.cost_for_task

def stubbed_cost_for_task(plan, task):
    if plan == "PLAN-17":
        raise KeyError("simulated schema drift in PLAN-17 task rollup")
    return _real_cost_for_task(plan, task)

api_costs.cost_for_task = stubbed_cost_for_task

try:
    app = Flask(__name__)
    app.register_blueprint(api_costs.bp)
    client = app.test_client()

    resp = client.get("/api/costs")
    # Must NOT 500 — the per-file catch should turn this into a 200 with
    # the bad file recorded in errors[].
    assert resp.status_code == 200, (
        f"per-file catch must keep route at 200: status={resp.status_code} "
        f"body={resp.data!r}"
    )
    envelope = resp.get_json()
    assert envelope.get("error") is None, (
        f"per-file catch must not set envelope.error (that path is for "
        f"whole-route 500s, not per-file errors): {envelope}"
    )
    payload = envelope["data"]

    # ── errors[] must name the bad path ──────────────────────────────────
    assert payload.get("errors"), (
        f"errors[] must be populated when a state file fails to roll up: "
        f"{payload!r}"
    )
    bad_path = ".claude/plans/PLAN-17-bad.state.json"
    matching = [e for e in payload["errors"] if bad_path in e]
    assert matching, (
        f"errors[] must name the bad state-file path {bad_path!r}: "
        f"{payload['errors']!r}"
    )
    # Exception type should be surfaced so operators can distinguish
    # schema drift (KeyError) from a parse error (JSONDecodeError).
    assert any("KeyError" in e for e in matching), (
        f"errors[] entry must name KeyError so operators can triage: "
        f"{matching!r}"
    )

    # ── per_task must contain entries from the OTHER (good) state file ──
    assert "PLAN-16-good" in payload["per_task"], (
        f"good plan must still appear in per_task despite bad sibling: "
        f"{payload['per_task']}"
    )
    good_entry = payload["per_task"]["PLAN-16-good"]
    assert "1" in good_entry, f"good plan's task 1 must be present: {good_entry}"
    assert good_entry["1"]["cost_usd"] == 0.2, (
        f"good plan's cost_usd should be unaffected by the bad sibling: "
        f"{good_entry['1']}"
    )

    # ── Bad plan should NOT appear in per_task as a stale empty dict ────
    # (The route uses a local plan_entry that's only published on success.)
    assert "PLAN-17-bad" not in payload["per_task"], (
        f"bad plan must not leak into per_task as an empty placeholder: "
        f"{payload['per_task']}"
    )
finally:
    api_costs.cost_for_task = _real_cost_for_task
sys.exit(0)
PY
  pass "scenario 16 (per-file KeyError caught; errors[] populated; good plan still renders)"
else
  fail "scenario 16 (per-file catch)"
fi

# ─── Scenario 17: /api/workers — repo-root anchoring works regardless of cwd
# Regression for PLAN-09 T1 acceptance #1: previously _last_log_for_task and
# _list_worktrees used Path.cwd() to find .claude/state — fragile when Flask
# is launched from outside the repo root (systemd ExecStart, cron). The fix
# caches a `_REPO_ROOT` resolved via `git rev-parse --show-toplevel` at
# module load. This test verifies the helpers honour _REPO_ROOT instead of
# the live cwd by monkey-patching the module-level constant to point at a
# tmpdir, then chdir'ing somewhere unrelated and checking the helpers still
# find the manifest + run-file in the patched root.
echo "--- 17: api_workers repo-root anchoring honours _REPO_ROOT, not Path.cwd() ---"
SCEN17_DIR="$TMPROOT/scen17"
mkdir -p "$SCEN17_DIR/.claude/state"
# Active worktrees manifest pointing at a path that exists under the patched
# root — _list_worktrees skips entries whose `resolved` Path doesn't exist,
# so the directory must actually be on disk for the row to render.
mkdir -p "$SCEN17_DIR/wt-plan99-t7"
echo "wt-plan99-t7" > "$SCEN17_DIR/.claude/state/active_worktrees.txt"
# A run-file matching the worker's glob — used by _last_log_for_task to
# build the last_log preview for task 7.
cat > "$SCEN17_DIR/.claude/state/run-plan99-t7-r1.json" <<'JSON'
{"type": "result", "result": "anchored preview", "is_error": false}
JSON
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" SCEN17_DIR="$SCEN17_DIR" run_py <<'PY'; then
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
# Chdir somewhere with NO `.claude/state/` so a regression to Path.cwd()
# would yield empty results and the assertions would fail.
os.chdir("/")
from dashboard import api_workers

# Override the module-level cache — this is the contract a Flask process
# would get if launched from outside the repo root: _init_repo_root() ran
# at import time, the value is sticky, and request-time cwd changes don't
# leak into helper behaviour.
api_workers._REPO_ROOT = Path(os.environ["SCEN17_DIR"])

# ── _last_log_for_task honours _REPO_ROOT ──────────────────────────────
preview = api_workers._last_log_for_task(7)
assert preview == "anchored preview", (
    f"_last_log_for_task should resolve against _REPO_ROOT, not Path.cwd(); "
    f"got {preview!r}"
)

# ── _list_worktrees honours _REPO_ROOT and returns (worktrees, err) ────
worktrees, manifest_err = api_workers._list_worktrees()
assert manifest_err is None, (
    f"manifest read should succeed on clean fixture: {manifest_err!r}"
)
assert len(worktrees) == 1, (
    f"_list_worktrees should resolve manifest against _REPO_ROOT and "
    f"return the one valid entry; got {worktrees!r}"
)
entry = worktrees[0]
assert entry["task_n"] == 7, f"task_n parse: {entry!r}"
assert entry["branch"] == "claude/plan-99-task-7", f"branch derive: {entry!r}"
assert entry["last_log"] == "anchored preview", (
    f"last_log should reflect anchored preview: {entry!r}"
)

# ── /api/workers route surfaces data.errors as a list, envelope.error None
from flask import Flask
app = Flask(__name__)
app.register_blueprint(api_workers.bp)
client = app.test_client()
resp = client.get("/api/workers")
assert resp.status_code == 200, f"status: {resp.status_code}"
envelope = resp.get_json()
assert envelope.get("error") is None, (
    f"happy path must NOT set envelope.error — per-source failures route to "
    f"data.errors[] instead: {envelope!r}"
)
payload = envelope["data"]
for k in ("processes", "active_worktrees", "errors"):
    assert k in payload, f"payload missing key {k!r}: {payload}"
assert isinstance(payload["errors"], list), (
    f"errors must be a list (string list convention): {payload['errors']!r}"
)
assert payload["active_worktrees"], (
    f"active_worktrees should contain the anchored entry: {payload!r}"
)
sys.exit(0)
PY
  pass "scenario 17 (api_workers honours _REPO_ROOT regardless of cwd)"
else
  fail "scenario 17 (api_workers repo-root anchoring)"
fi

# ─── Scenario 18: corrupt run-file does NOT crash, DOES leave a breadcrumb
# Regression for PLAN-09 T1 acceptance #2: the bare `except Exception` in
# _last_log_for_task swallowed every failure silently — including the case
# where a worker wrote a half-flushed or otherwise unparseable run-file,
# leaving the operator with an empty `last_log` column and no diagnostic.
# The fix narrows the catch to (OSError, JSONDecodeError, UnicodeDecodeError)
# and emits a WARNING log when JSON decode failures yielded no preview, so
# corrupt run-files leave a paper trail in the dashboard log.
echo "--- 18: corrupt run-file → returns None + emits log breadcrumb ---"
SCEN18_DIR="$TMPROOT/scen18"
mkdir -p "$SCEN18_DIR/.claude/state"
# A truly unparseable run-file: starts with `{`, no closing brace, and the
# body isn't valid JSONL either. Both the single-object json.loads AND every
# JSONL fallback line will raise JSONDecodeError.
cat > "$SCEN18_DIR/.claude/state/run-plan99-t8-r1.json" <<'JSON'
{ this is not valid json
and neither is this line
JSON
if KIT_SCRIPTS_DIR="$KIT_SCRIPTS_DIR" SCEN18_DIR="$SCEN18_DIR" run_py <<'PY'; then
import io, logging, os, sys
from pathlib import Path
sys.path.insert(0, os.environ["KIT_SCRIPTS_DIR"])
from dashboard import api_workers

api_workers._REPO_ROOT = Path(os.environ["SCEN18_DIR"])

# Capture the dashboard logger's output so we can assert on the breadcrumb.
buf = io.StringIO()
handler = logging.StreamHandler(buf)
handler.setLevel(logging.WARNING)
handler.setFormatter(logging.Formatter("%(levelname)s %(name)s: %(message)s"))
dash_log = logging.getLogger("dashboard")
prior_level = dash_log.level
dash_log.addHandler(handler)
dash_log.setLevel(logging.WARNING)

try:
    result = api_workers._last_log_for_task(8)
finally:
    dash_log.removeHandler(handler)
    dash_log.setLevel(prior_level)

# ── Panel must NOT crash: result is None, not an exception ─────────────
assert result is None, (
    f"corrupt run-file must yield None (not raise, not return garbage); "
    f"got {result!r}"
)

# ── Breadcrumb must be emitted ─────────────────────────────────────────
log_output = buf.getvalue()
assert "WARNING" in log_output, (
    f"corrupt run-file must emit a WARNING-level breadcrumb so the "
    f"operator sees that a run-file was unparseable; got:\n{log_output!r}"
)
assert "api_workers" in log_output, (
    f"breadcrumb should be tagged with the api_workers module so logs "
    f"are grep-able: {log_output!r}"
)
assert "decode" in log_output.lower() or "corrupt" in log_output.lower(), (
    f"breadcrumb should mention the decode failure / corruption: "
    f"{log_output!r}"
)
assert "run-plan99-t8-r1.json" in log_output, (
    f"breadcrumb should name the specific run-file so the operator can "
    f"locate it: {log_output!r}"
)

# ── /api/workers must still 200 with the bad file in place ─────────────
# The route reads _list_worktrees + _list_processes; neither calls
# _last_log_for_task for a task_n that isn't in the manifest. To exercise
# the route end-to-end with the corrupt file in scope we add a manifest
# entry that derives task_n=8, which forces _last_log_for_task to run.
# The route must STILL return 200 and a valid envelope.
os.makedirs(api_workers._REPO_ROOT / "wt-plan99-t8", exist_ok=True)
(api_workers._REPO_ROOT / ".claude/state/active_worktrees.txt").write_text(
    "wt-plan99-t8\n", encoding="utf-8"
)

from flask import Flask
app = Flask(__name__)
app.register_blueprint(api_workers.bp)
client = app.test_client()
resp = client.get("/api/workers")
assert resp.status_code == 200, (
    f"panel must not crash on a corrupt run-file; status={resp.status_code} "
    f"body={resp.data!r}"
)
envelope = resp.get_json()
payload = envelope["data"]
# The worktree row renders, and its last_log is None — not an exception.
assert len(payload["active_worktrees"]) == 1, (
    f"corrupt run-file must not nuke the worktrees panel: {payload!r}"
)
assert payload["active_worktrees"][0]["last_log"] is None, (
    f"corrupt run-file must yield last_log=None on the rendered row: "
    f"{payload['active_worktrees'][0]!r}"
)
sys.exit(0)
PY
  pass "scenario 18 (corrupt run-file → None + WARNING breadcrumb, panel renders)"
else
  fail "scenario 18 (corrupt run-file breadcrumb)"
fi

# ─── Summary ───────────────────────────────────────────────────────────────
echo ""
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [ "$TESTS_FAILED" -gt 0 ]; then
  echo "RESULT: $TESTS_FAILED/$TOTAL scenario(s) failed" >&2
  exit 1
fi
echo "RESULT: $TESTS_PASSED/$TOTAL scenarios passed"
exit 0
