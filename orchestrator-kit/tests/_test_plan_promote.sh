#!/usr/bin/env bash
# Smoke test: verify plan-promote.sh inter-plan ordering logic.
#
# Usage: bash orchestrator-kit/tests/_test_plan_promote.sh
#
# Seven scenarios exercised:
#   1. Candidate with requires=[PLAN-AA], AA still active in_progress → exit 1
#   2. Candidate with requires=[], or empty array → exit 0
#   3. Candidate with requires=[PLAN-AA], AA archived as done → exit 0
#   4. Candidate with requires=[PLAN-AA], AA archived as blocked → exit 3 (permanent)
#   5. Candidate with no requires field → exit 0
#   6. Candidate requires PLAN-ZZ which doesn't exist anywhere → exit 1
#   7. Candidate with requires=[PLAN-AA, PLAN-CC], AA archived blocked, CC done → exit 3
#
# Exit code: 0 = all pass, 1 = any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROMOTE_SCRIPT="$KIT_ROOT/.claude/scripts/plan-promote.sh"

TESTS_FAILED=0

fail() { echo "FAIL: $*" >&2; TESTS_FAILED=$((TESTS_FAILED + 1)); }
pass() { echo "PASS: $*"; }

# Build a temporary .claude/plans directory tree
TMPROOT=$(mktemp -d /tmp/_test_plan_promote.XXXXXX)
PLANS_DIR="$TMPROOT/.claude/plans"
ARCHIVE_DIR="$TMPROOT/.claude/plans/archive"
mkdir -p "$PLANS_DIR" "$ARCHIVE_DIR"

make_state() {
  local path="$1"
  local content="$2"
  printf '%s' "$content" > "$path"
}

# -- Scenario 1: BB requires AA which is still in_progress --
make_state "$PLANS_DIR/PLAN-AA-base.state.json" \
  '{"plan_file":"x","status":"in_progress","schema_version":3,"total_tasks":1,"tasks":{"1":{}}}'
make_state "$PLANS_DIR/PLAN-BB-dep.state.json" \
  '{"plan_file":"y","status":"in_progress","schema_version":3,"requires":["PLAN-AA"],"total_tasks":1,"tasks":{"1":{}}}'

(cd "$TMPROOT" && bash "$PROMOTE_SCRIPT" ".claude/plans/PLAN-BB-dep.state.json" >/dev/null 2>&1)
_rc=$?
if [ "$_rc" = "1" ]; then
  pass "scenario 1: BB waits on in_progress AA (exit 1)"
else
  fail "scenario 1: expected exit 1, got $_rc"
fi

# -- Scenario 2: AA has empty requires → exit 0 --
make_state "$PLANS_DIR/PLAN-CC-empty-req.state.json" \
  '{"plan_file":"z","status":"in_progress","schema_version":3,"requires":[],"total_tasks":1,"tasks":{"1":{}}}'

(cd "$TMPROOT" && bash "$PROMOTE_SCRIPT" ".claude/plans/PLAN-CC-empty-req.state.json" >/dev/null 2>&1)
_rc=$?
if [ "$_rc" = "0" ]; then
  pass "scenario 2: empty requires → exit 0"
else
  fail "scenario 2: expected exit 0, got $_rc"
fi

# -- Scenario 3: BB requires AA, AA archived as done → exit 0 --
jq '.status = "done"' "$PLANS_DIR/PLAN-AA-base.state.json" > "$ARCHIVE_DIR/PLAN-AA-base.state.json"

(cd "$TMPROOT" && bash "$PROMOTE_SCRIPT" ".claude/plans/PLAN-BB-dep.state.json" >/dev/null 2>&1)
_rc=$?
if [ "$_rc" = "0" ]; then
  pass "scenario 3: BB promoted after AA archived:done (exit 0)"
else
  fail "scenario 3: expected exit 0, got $_rc"
fi

# -- Scenario 4: BB requires AA, AA archived as blocked → exit 3 (permanent) --
jq '.status = "blocked"' "$PLANS_DIR/PLAN-AA-base.state.json" > "$ARCHIVE_DIR/PLAN-AA-base.state.json"

(cd "$TMPROOT" && bash "$PROMOTE_SCRIPT" ".claude/plans/PLAN-BB-dep.state.json" >/dev/null 2>&1)
_rc=$?
if [ "$_rc" = "3" ]; then
  pass "scenario 4: BB permanently blocked when AA archived:blocked (exit 3)"
else
  fail "scenario 4: expected exit 3, got $_rc"
fi
# Restore AA archived as done for remaining tests
jq '.status = "done"' "$PLANS_DIR/PLAN-AA-base.state.json" > "$ARCHIVE_DIR/PLAN-AA-base.state.json"

# -- Scenario 5: plan with no requires field at all → exit 0 --
make_state "$PLANS_DIR/PLAN-DD-no-req.state.json" \
  '{"plan_file":"w","status":"in_progress","schema_version":3,"total_tasks":1,"tasks":{"1":{}}}'

(cd "$TMPROOT" && bash "$PROMOTE_SCRIPT" ".claude/plans/PLAN-DD-no-req.state.json" >/dev/null 2>&1)
_rc=$?
if [ "$_rc" = "0" ]; then
  pass "scenario 5: no requires field → exit 0"
else
  fail "scenario 5: expected exit 0, got $_rc"
fi

# -- Scenario 6: plan requires PLAN-ZZ which doesn't exist anywhere → exit 1 --
make_state "$PLANS_DIR/PLAN-EE-missing-dep.state.json" \
  '{"plan_file":"v","status":"in_progress","schema_version":3,"requires":["PLAN-ZZ"],"total_tasks":1,"tasks":{"1":{}}}'

(cd "$TMPROOT" && bash "$PROMOTE_SCRIPT" ".claude/plans/PLAN-EE-missing-dep.state.json" >/dev/null 2>&1)
_rc=$?
if [ "$_rc" = "1" ]; then
  pass "scenario 6: PLAN-ZZ not found anywhere → exit 1"
else
  fail "scenario 6: expected exit 1, got $_rc"
fi

# -- Scenario 7: plan requires [PLAN-AA (blocked), PLAN-FF (done)] → exit 3 (permanent) --
# Mixed case: one upstream is permanently blocked, another is done. The permanently
# blocked one should dominate and return exit 3, not exit 1.
jq '.status = "blocked"' "$PLANS_DIR/PLAN-AA-base.state.json" > "$ARCHIVE_DIR/PLAN-AA-base.state.json"
make_state "$ARCHIVE_DIR/PLAN-FF-done.state.json" \
  '{"plan_file":"ff","status":"done","schema_version":3,"total_tasks":1,"tasks":{"1":{}}}'
make_state "$PLANS_DIR/PLAN-GG-mixed-dep.state.json" \
  '{"plan_file":"gg","status":"in_progress","schema_version":3,"requires":["PLAN-AA","PLAN-FF"],"total_tasks":1,"tasks":{"1":{}}}'

(cd "$TMPROOT" && bash "$PROMOTE_SCRIPT" ".claude/plans/PLAN-GG-mixed-dep.state.json" >/dev/null 2>&1)
_rc=$?
if [ "$_rc" = "3" ]; then
  pass "scenario 7: GG permanently blocked (AA blocked, FF done) → exit 3"
else
  fail "scenario 7: expected exit 3, got $_rc"
fi

# Cleanup
rm -rf "$TMPROOT"

echo ""
if [ "$TESTS_FAILED" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$TESTS_FAILED test(s) failed." >&2
  exit 1
fi
