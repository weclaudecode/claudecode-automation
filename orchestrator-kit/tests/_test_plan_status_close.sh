#!/usr/bin/env bash
# Smoke test for close_plan_status_issue in _dispatcher_lib.sh.
#
# Background — PLAN-12 T2 / kit issue #93:
# plan-status.sh creates a `[plan-NN] status` issue at first dashboard
# refresh. Before this fix, that issue lived forever in the backlog after
# the plan archived. The new contract:
#
#   1. plan-status.sh persists the issue number to state.json as
#      `plan_status_issue` at create time (so the close path doesn't have
#      to re-grep the issue title from the archived state).
#   2. orchestrator.sh, on plan archive, reads `plan_status_issue` BEFORE
#      the mv, then calls close_plan_status_issue (this function) AFTER
#      the mv. The function posts a brief final-ledger comment then
#      closes the issue.
#
# Scenarios:
#   1. Happy path — non-empty issue number + a fixture state.json with
#      merged + blocked tasks: expect 2 gh calls (comment, close), comment
#      body carries the counts and merged PR list.
#   2. Empty issue number — silent no-op, zero gh calls. Supports plans
#      that opted out of dashboard tracking or were ingested before
#      PLAN-12 T2 added the field.
#   3. gh failures don't fail the function — best-effort guarantee, even
#      when comment and close both fail the function returns 0 and logs
#      warnings to stderr so the calling tick survives.
#
# Mock strategy: tiny `gh` stub hoisted onto $PATH that logs one filtered
# line per call (drops --body and its value to keep counting line-
# delimited) and saves --body payloads to side files. Same pattern as
# `_test_review_fallback.sh`.
#
# Runs offline. No real gh, no network.
#
# Usage: bash orchestrator-kit/tests/_test_plan_status_close.sh
# Exit:  0 = all pass, 1 = any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$KIT_ROOT/.claude/scripts/_dispatcher_lib.sh"

TESTS_FAILED=0
TESTS_PASSED=0
fail() { echo "FAIL: $*" >&2; TESTS_FAILED=$((TESTS_FAILED + 1)); }
pass() { echo "PASS: $*"; TESTS_PASSED=$((TESTS_PASSED + 1)); }

TMPROOT=$(mktemp -d /tmp/_test_plan_status_close.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT INT TERM

# ─── Mock gh ──────────────────────────────────────────────────────────────────
# Logs one filtered line per call (drops "--body <value>" so the log stays
# line-delimited for wc -l counting) and captures --body payloads to side
# files indexed by invocation count.
GH_STUB_DIR="$TMPROOT/bin"
mkdir -p "$GH_STUB_DIR"
cat > "$GH_STUB_DIR/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
LOG_FILE="${GH_STUB_LOG:-/dev/null}"
ARGS_DIR="${GH_STUB_ARGS_DIR:-}"

filtered=()
skip_next=0
for arg in "$@"; do
  if [ "$skip_next" = "1" ]; then
    skip_next=0
    continue
  fi
  if [ "$arg" = "--body" ]; then
    filtered+=("$arg")
    skip_next=1
    continue
  fi
  filtered+=("$arg")
done

printf '%s\n' "${filtered[*]}" >> "$LOG_FILE"

if [ -n "$ARGS_DIR" ] && [ -d "$ARGS_DIR" ]; then
  INV=$(wc -l < "$LOG_FILE" | tr -d ' ')
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--body" ]; then
      printf '%s' "$arg" > "$ARGS_DIR/body-$INV"
      break
    fi
    prev="$arg"
  done
fi

exit "${GH_STUB_EXIT:-0}"
GHSCRIPT
chmod +x "$GH_STUB_DIR/gh"

export PATH="$GH_STUB_DIR:$PATH"

# shellcheck source=../.claude/scripts/_dispatcher_lib.sh
source "$LIB"

# ─── Fixture: archived state.json with mixed task statuses ────────────────────
# Two merged (with PRs), one blocked. Matches the schema close_plan_status_issue
# reads from. plan_status_issue itself is unused by the function but is set
# here to document the field's location on real archived state files.
FIXTURE="$TMPROOT/PLAN-99-foo.state.json"
cat > "$FIXTURE" <<'JSON'
{
  "plan_file": ".claude/plans/archive/PLAN-99-foo.md",
  "total_tasks": 3,
  "status": "done",
  "plan_status_issue": 42,
  "tasks": {
    "1": {"title": "task one", "status": "merged", "pr": 101},
    "2": {"title": "task two", "status": "merged", "pr": 102},
    "3": {"title": "task three", "status": "blocked", "pr": null}
  }
}
JSON

# ─── Scenario 1: happy path — comment + close called with the right args ─────
echo "--- 1: happy path — issue 42 commented + closed ---"

S1_LOG="$TMPROOT/s1.log"
S1_ARGS_DIR="$TMPROOT/s1-args"
mkdir -p "$S1_ARGS_DIR"
: > "$S1_LOG"

GH_STUB_LOG="$S1_LOG" GH_STUB_ARGS_DIR="$S1_ARGS_DIR" \
  close_plan_status_issue 42 99 "done" "$FIXTURE" \
  > "$TMPROOT/s1.stdout" 2> "$TMPROOT/s1.stderr"
RC=$?

if [ "$RC" = "0" ]; then
  pass "scenario 1: function returns 0"
else
  fail "scenario 1: function returned $RC (expected 0); stderr: $(cat "$TMPROOT/s1.stderr")"
fi

CALL_COUNT=$(wc -l < "$S1_LOG" | tr -d ' ')
if [ "$CALL_COUNT" = "2" ]; then
  pass "scenario 1: exactly 2 gh calls (comment + close)"
else
  fail "scenario 1: expected 2 gh calls, got $CALL_COUNT — log:
$(cat "$S1_LOG")"
fi

if grep -qE "^issue comment 42 --body$" "$S1_LOG"; then
  pass "scenario 1: gh issue comment 42 --body call present"
else
  fail "scenario 1: no 'gh issue comment 42 --body' in log:
$(cat "$S1_LOG")"
fi

if grep -qE "^issue close 42$" "$S1_LOG"; then
  pass "scenario 1: gh issue close 42 call present"
else
  fail "scenario 1: no 'gh issue close 42' in log:
$(cat "$S1_LOG")"
fi

BODY_1="$S1_ARGS_DIR/body-1"
if [ -f "$BODY_1" ] && grep -q "Plan 99 archived" "$BODY_1"; then
  pass "scenario 1: ledger header names the plan number"
else
  fail "scenario 1: ledger header missing — content:
$(cat "$BODY_1" 2>/dev/null || echo '(no body file)')"
fi

if [ -f "$BODY_1" ] && grep -q "2 merged" "$BODY_1"; then
  pass "scenario 1: ledger body reports 2 merged"
else
  fail "scenario 1: ledger missing '2 merged'"
fi

if [ -f "$BODY_1" ] && grep -q "1 blocked" "$BODY_1"; then
  pass "scenario 1: ledger body reports 1 blocked"
else
  fail "scenario 1: ledger missing '1 blocked'"
fi

if [ -f "$BODY_1" ] && grep -q "#101" "$BODY_1" && grep -q "#102" "$BODY_1"; then
  pass "scenario 1: ledger lists merged PRs #101 and #102"
else
  fail "scenario 1: ledger missing one of #101/#102 — content:
$(cat "$BODY_1" 2>/dev/null || echo '(no body file)')"
fi

# ─── Scenario 2: empty issue number → silent no-op ────────────────────────────
echo "--- 2: empty issue number — silent no-op ---"

S2_LOG="$TMPROOT/s2.log"
: > "$S2_LOG"

GH_STUB_LOG="$S2_LOG" \
  close_plan_status_issue "" 99 "done" "$FIXTURE" \
  > "$TMPROOT/s2.stdout" 2> "$TMPROOT/s2.stderr"
RC=$?

if [ "$RC" = "0" ]; then
  pass "scenario 2: function returns 0 (silent skip)"
else
  fail "scenario 2: function returned $RC (expected 0); stderr: $(cat "$TMPROOT/s2.stderr")"
fi

CALL_COUNT=$(wc -l < "$S2_LOG" | tr -d ' ')
if [ "$CALL_COUNT" = "0" ]; then
  pass "scenario 2: no gh calls"
else
  fail "scenario 2: expected 0 gh calls, got $CALL_COUNT — log:
$(cat "$S2_LOG")"
fi

# ─── Scenario 3: gh failures — function still returns 0 (best-effort) ─────────
echo "--- 3: gh failure — function still returns 0 ---"

S3_LOG="$TMPROOT/s3.log"
: > "$S3_LOG"

GH_STUB_LOG="$S3_LOG" GH_STUB_EXIT=1 \
  close_plan_status_issue 42 99 "done" "$FIXTURE" \
  > "$TMPROOT/s3.stdout" 2> "$TMPROOT/s3.stderr"
RC=$?

if [ "$RC" = "0" ]; then
  pass "scenario 3: function returns 0 despite gh failures"
else
  fail "scenario 3: function returned $RC (expected 0 even on gh failure); stderr: $(cat "$TMPROOT/s3.stderr")"
fi

if grep -q "warning: failed to comment on plan-status #42" "$TMPROOT/s3.stderr"; then
  pass "scenario 3: comment failure logged as warning"
else
  fail "scenario 3: comment-failure warning missing — stderr:
$(cat "$TMPROOT/s3.stderr")"
fi

if grep -q "warning: failed to close plan-status #42" "$TMPROOT/s3.stderr"; then
  pass "scenario 3: close failure logged as warning"
else
  fail "scenario 3: close-failure warning missing — stderr:
$(cat "$TMPROOT/s3.stderr")"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [ "$TESTS_FAILED" -gt 0 ]; then
  echo "RESULT: $TESTS_FAILED/$TOTAL assertion(s) failed" >&2
  exit 1
fi
echo "RESULT: $TESTS_PASSED/$TOTAL assertions passed"
exit 0
