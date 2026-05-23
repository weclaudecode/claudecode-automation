#!/usr/bin/env bash
# Test harness for monitor-sweep.sh and its heuristics.
#
# Usage: bash orchestrator-kit/tests/test_monitor_sweep.sh
#
# Runs:
#   1. Framework smoke test — verifies monitor_finding is callable.
#   2. Fixture-driven heuristic tests — walks fixtures/monitor/*_positive.json
#      and *_negative.json (populated by tasks 2-6). No-op for task 1.
#
# Exit code: 0 = all pass, 1 = any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../.claude/scripts" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/monitor"
FRAMEWORK="$SCRIPTS_DIR/monitor-sweep.sh"

# Test mode: monitor_finding appends hashes here instead of calling gh.
MONITOR_TEST_MODE=1
export MONITOR_TEST_MODE
MONITOR_FINDINGS_OBSERVED=()

TESTS_FAILED=0

fail() {
  echo "FAIL: $*" >&2
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

assert_finding() {
  local hash="$1"
  local found=0
  local n="${#MONITOR_FINDINGS_OBSERVED[@]}"
  local i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${MONITOR_FINDINGS_OBSERVED[$i]}" = "$hash" ]; then
      found=1
      break
    fi
    i=$((i + 1))
  done
  if [ "$found" -eq 0 ]; then
    fail "expected finding '$hash'; observed: ${MONITOR_FINDINGS_OBSERVED[*]:-<none>}"
  fi
}

assert_no_finding() {
  local hash="$1"
  local n="${#MONITOR_FINDINGS_OBSERVED[@]}"
  local i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${MONITOR_FINDINGS_OBSERVED[$i]}" = "$hash" ]; then
      fail "unexpected finding '$hash'"
      return
    fi
    i=$((i + 1))
  done
}

# run_heuristic <heuristic_file> <fixture_state>
#
# Resets MONITOR_FINDINGS_OBSERVED, sets STATE_FILE to the fixture, then
# sources the heuristic. The framework's monitor_finding (already loaded) runs
# in test mode and appends to MONITOR_FINDINGS_OBSERVED instead of calling gh.
run_heuristic() {
  local heuristic_file="$1"
  local fixture_state="$2"

  MONITOR_FINDINGS_OBSERVED=()
  STATE_FILE="$fixture_state"
  export STATE_FILE

  # shellcheck disable=SC1090
  source "$heuristic_file"
}

# ── Load framework (defines monitor_finding; main body skipped via BASH_SOURCE guard) ──
# shellcheck disable=SC1090
source "$FRAMEWORK"

# ── Smoke test: framework loads without errors and monitor_finding is callable ──
echo "--- smoke test ---"
MONITOR_FINDINGS_OBSERVED=()

monitor_finding "smoke-test-hash" "Smoke test title" "Smoke test body"

assert_finding "smoke-test-hash"
echo "framework smoke-test ok"

# ── Fixture-driven heuristic tests (no-op until tasks 2-6 add fixtures) ──
FIXTURE_TESTS_RUN=0

for positive in "$FIXTURES_DIR"/*_positive.json; do
  [ -f "$positive" ] || continue

  base="${positive%_positive.json}"
  heuristic_name="$(basename "$base")"
  heuristic_file="$SCRIPTS_DIR/_heuristics/${heuristic_name}.sh"
  negative="${base}_negative.json"

  if [ ! -f "$heuristic_file" ]; then
    echo "SKIP: no heuristic file for $heuristic_name"
    continue
  fi

  echo "--- $heuristic_name positive ---"
  run_heuristic "$heuristic_file" "$positive"
  assert_finding "$heuristic_name"

  if [ -f "$negative" ]; then
    echo "--- $heuristic_name negative ---"
    run_heuristic "$heuristic_file" "$negative"
    assert_no_finding "$heuristic_name"
  fi

  FIXTURE_TESTS_RUN=$((FIXTURE_TESTS_RUN + 1))
done

# ── H1: stuck orch:needs-robbie PR detector ──
# Tested explicitly because the fixture name prefix ("h1") differs from the
# heuristic filename ("h1_stuck_needs_robbie"), so the auto-discovery loop
# above skips it. The expected finding hash is "H1-PR99" (PR number embedded).
echo "--- h1_stuck_needs_robbie positive ---"
run_heuristic "$SCRIPTS_DIR/_heuristics/h1_stuck_needs_robbie.sh" \
  "$FIXTURES_DIR/h1_positive.json"
assert_finding "H1-PR99"
FIXTURE_TESTS_RUN=$((FIXTURE_TESTS_RUN + 1))

echo "--- h1_stuck_needs_robbie negative ---"
run_heuristic "$SCRIPTS_DIR/_heuristics/h1_stuck_needs_robbie.sh" \
  "$FIXTURES_DIR/h1_negative.json"
assert_no_finding "H1-PR99"

# ── H2: silent worker-failed-3x detector ──
# Tested explicitly because the fixture prefix ("h2") differs from the heuristic
# filename ("h2_silent_block"), and because $DECISIONS_FILE must be pointed at
# the fixture .md files rather than the real .claude/state/decisions.md.
echo "--- h2_silent_block positive ---"
export DECISIONS_FILE="$FIXTURES_DIR/h2_decisions_empty.md"
run_heuristic "$SCRIPTS_DIR/_heuristics/h2_silent_block.sh" \
  "$FIXTURES_DIR/h2_positive.json"
unset DECISIONS_FILE
assert_finding "H2-PLAN01-T3"
FIXTURE_TESTS_RUN=$((FIXTURE_TESTS_RUN + 1))

echo "--- h2_silent_block negative ---"
export DECISIONS_FILE="$FIXTURES_DIR/h2_decisions_active.md"
run_heuristic "$SCRIPTS_DIR/_heuristics/h2_silent_block.sh" \
  "$FIXTURES_DIR/h2_negative.json"
unset DECISIONS_FILE
assert_no_finding "H2-PLAN01-T3"

# ── H3: slow-plan detector ──
# Tested explicitly because the fixture prefix ("h3") differs from the heuristic
# filename ("h3_slow_plan"), so auto-discovery skips it.
# Positive: ingested_at 8 days ago, 1/10 merged (10% < 30%) → fires H3-PLAN01.
# Negative: ingested_at 8 days ago, 5/10 merged (50% >= 30%) → no fire.
echo "--- h3_slow_plan positive ---"
run_heuristic "$SCRIPTS_DIR/_heuristics/h3_slow_plan.sh" \
  "$FIXTURES_DIR/h3_positive.json"
assert_finding "H3-PLAN01"
FIXTURE_TESTS_RUN=$((FIXTURE_TESTS_RUN + 1))

echo "--- h3_slow_plan negative ---"
run_heuristic "$SCRIPTS_DIR/_heuristics/h3_slow_plan.sh" \
  "$FIXTURES_DIR/h3_negative.json"
assert_no_finding "H3-PLAN01"

# ── H5: deadlock detector ──
# Tested explicitly because H5 fixtures are .txt (not .json, so auto-discovery
# skips them) and because LOG_FILE must be pointed at the fixture log.
# Uses h1_positive.json as STATE_FILE (plan_file = PLAN-01-test.md → hash PLAN01).
echo "--- h5_deadlock positive ---"
export LOG_FILE="$FIXTURES_DIR/h5_log_positive.txt"
run_heuristic "$SCRIPTS_DIR/_heuristics/h5_deadlock.sh" \
  "$FIXTURES_DIR/h1_positive.json"
unset LOG_FILE
assert_finding "H5-PLAN01-RECENT"
FIXTURE_TESTS_RUN=$((FIXTURE_TESTS_RUN + 1))

echo "--- h5_deadlock negative ---"
export LOG_FILE="$FIXTURES_DIR/h5_log_negative.txt"
run_heuristic "$SCRIPTS_DIR/_heuristics/h5_deadlock.sh" \
  "$FIXTURES_DIR/h1_positive.json"
unset LOG_FILE
assert_no_finding "H5-PLAN01-RECENT"

# ── H4: reviewer-flake detector ──
# Tested explicitly because the fixture prefix ("h4_reviews") differs from the
# heuristic filename ("h4_reviewer_flake"), so auto-discovery skips it.
# Positive: PR 99, 3 reviews on SHA abc1234 with alternating verdicts → H4-PR99-SHAabc1234.
# Negative: PR 99, only 2 reviews on same SHA → no fire.
echo "--- h4_reviewer_flake positive ---"
run_heuristic "$SCRIPTS_DIR/_heuristics/h4_reviewer_flake.sh" \
  "$FIXTURES_DIR/h4_reviews_positive.json"
assert_finding "H4-PR99-SHAabc1234"
FIXTURE_TESTS_RUN=$((FIXTURE_TESTS_RUN + 1))

echo "--- h4_reviewer_flake negative ---"
run_heuristic "$SCRIPTS_DIR/_heuristics/h4_reviewer_flake.sh" \
  "$FIXTURES_DIR/h4_reviews_negative.json"
assert_no_finding "H4-PR99-SHAabc1234"

# ── H6: test-fail PR detector ──
# Tested explicitly because the fixture prefix ("h6_run") differs from the
# heuristic filename ("h6_test_fail_pr"), so auto-discovery skips it.
# Positive: task 2 completed with tests_result=fail and has PR 55 → H6-T2-R0.
# Negative: task 2 completed with tests_result=pass → no fire.
echo "--- h6_test_fail_pr positive ---"
run_heuristic "$SCRIPTS_DIR/_heuristics/h6_test_fail_pr.sh" \
  "$FIXTURES_DIR/h6_run_positive.json"
assert_finding "H6-T2-R0"
FIXTURE_TESTS_RUN=$((FIXTURE_TESTS_RUN + 1))

echo "--- h6_test_fail_pr negative ---"
run_heuristic "$SCRIPTS_DIR/_heuristics/h6_test_fail_pr.sh" \
  "$FIXTURES_DIR/h6_run_negative.json"
assert_no_finding "H6-T2-R0"

# ── Summary ──
if [ "$TESTS_FAILED" -gt 0 ]; then
  echo "RESULT: $TESTS_FAILED failure(s) (fixture tests run: $FIXTURE_TESTS_RUN)" >&2
  exit 1
fi

echo "RESULT: all tests passed (fixture tests run: $FIXTURE_TESTS_RUN)"
exit 0
