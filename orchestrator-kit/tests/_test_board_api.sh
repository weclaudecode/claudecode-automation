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

# Different (plan, task) keys should be free to land anywhere; we just
# verify the function is total over the pool and returns the {name, seed,
# role} shape.
names = {api_board.agent_for_task("PLAN-05", t, pool, "worker")["name"]
         for t in range(20)}
assert names.issubset(set(pool)), f"agent names must be drawn from pool: {names - set(pool)}"

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

# ─── Summary ───────────────────────────────────────────────────────────────
echo ""
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [ "$TESTS_FAILED" -gt 0 ]; then
  echo "RESULT: $TESTS_FAILED/$TOTAL scenario(s) failed" >&2
  exit 1
fi
echo "RESULT: $TESTS_PASSED/$TOTAL scenarios passed"
exit 0
