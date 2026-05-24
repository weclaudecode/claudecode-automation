#!/usr/bin/env bash
# Parallel-test for acquire_stack_lock / release_stack_lock.
#
# Usage: bash orchestrator-kit/tests/_test_stack_lock.sh
#
# Scenarios exercised:
#   1. Basic acquire + release: lock dir appears, then disappears.
#   2. Same-PID idempotency: double-acquire from same $$ succeeds.
#   3. Parallel contention (fail-fast): a second process cannot acquire
#      while the first holds the lock; gets exit 1.
#   4. Stale-PID break: a lock whose PID file contains a dead PID is
#      auto-broken and the new caller acquires successfully.
#
# Exit code: 0 = pass, 1 = any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$KIT_ROOT/.claude/scripts/_dispatcher_lib.sh"

TESTS_FAILED=0

fail() { echo "FAIL: $*" >&2; TESTS_FAILED=$((TESTS_FAILED + 1)); }
pass() { echo "PASS: $*"; }

# We need a real git repo root for acquire_stack_lock to resolve paths.
# The kit root IS the git repo root for this source tree.
cd "$KIT_ROOT" || exit 1

# Source the library so acquire_stack_lock / release_stack_lock are available.
# shellcheck source=../orchestrator-kit/.claude/scripts/_dispatcher_lib.sh
source "$LIB"

# All scenarios use a test env to avoid touching the "dev" namespace.
TEST_ENV="test"
LOCK_BASE="$(git rev-parse --show-toplevel)/.claude/state/${TEST_ENV}/cdk-stack-locks"
STACK="test_stack_$$"

cleanup() {
  rm -rf "${LOCK_BASE:?}/${STACK}.lock.d" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Scenario 1: basic acquire + release
# ---------------------------------------------------------------------------
echo "--- Scenario 1: basic acquire + release ---"

if acquire_stack_lock "$STACK" "$TEST_ENV"; then
  pass "acquire_stack_lock: initial acquire succeeded"
else
  fail "acquire_stack_lock: initial acquire returned non-zero"
fi

lockdir="${LOCK_BASE}/${STACK}.lock.d"
if [ -d "$lockdir" ]; then
  pass "lock dir exists after acquire"
else
  fail "lock dir missing after acquire"
fi

pid_in_file=$(cat "$lockdir/pid" 2>/dev/null || echo "")
if [ "$pid_in_file" = "$$" ]; then
  pass "PID file contains correct PID ($$)"
else
  fail "PID file contains '$pid_in_file', expected $$"
fi

if release_stack_lock "$STACK" "$TEST_ENV"; then
  pass "release_stack_lock: release succeeded"
else
  fail "release_stack_lock: release returned non-zero"
fi

if [ -d "$lockdir" ]; then
  fail "lock dir still present after release"
else
  pass "lock dir removed after release"
fi

# ---------------------------------------------------------------------------
# Scenario 2: same-PID idempotency
# ---------------------------------------------------------------------------
echo "--- Scenario 2: same-PID idempotency ---"

if acquire_stack_lock "$STACK" "$TEST_ENV"; then
  pass "acquire 1st: success"
else
  fail "acquire 1st: failed unexpectedly"
fi

if acquire_stack_lock "$STACK" "$TEST_ENV"; then
  pass "acquire 2nd (same PID): idempotent success"
else
  fail "acquire 2nd (same PID): returned non-zero (expected 0)"
fi

if release_stack_lock "$STACK" "$TEST_ENV"; then
  pass "release after double-acquire: success"
else
  fail "release after double-acquire: failed"
fi

[ -d "$lockdir" ] && fail "lock dir lingers after release" || pass "lock dir gone after release"

# ---------------------------------------------------------------------------
# Scenario 3: parallel contention — fail-fast
# ---------------------------------------------------------------------------
echo "--- Scenario 3: parallel contention (fail-fast) ---"

# Spawn a separate bash process (not a subshell) that acquires the lock,
# sleeps 2 s, then releases. A separate process has a genuinely different
# PID from the test script's $$, so the fail-fast path is exercised.
bash -c "
  source '$LIB'
  acquire_stack_lock '$STACK' '$TEST_ENV' >/dev/null 2>&1
  sleep 2
  release_stack_lock '$STACK' '$TEST_ENV' >/dev/null 2>&1
" &
HOLDER_PID=$!

# Give the holder process ~200 ms to acquire before we try from the parent.
sleep 0.2

# Parent (different PID from the subshell) tries to acquire — must fail.
if acquire_stack_lock "$STACK" "$TEST_ENV" 2>/dev/null; then
  fail "parallel acquire should have been blocked (fail-fast), but succeeded"
else
  pass "parallel acquire correctly returned exit 1 (fail-fast)"
fi

# Wait for the holder to finish releasing.
wait "$HOLDER_PID" 2>/dev/null || true

# Now the lock should be gone; parent can acquire.
if acquire_stack_lock "$STACK" "$TEST_ENV"; then
  pass "acquire after holder released: success"
else
  fail "acquire after holder released: failed"
fi
release_stack_lock "$STACK" "$TEST_ENV"

# ---------------------------------------------------------------------------
# Scenario 4: stale-PID break
# ---------------------------------------------------------------------------
echo "--- Scenario 4: stale-PID break ---"

# Manually plant a lock dir with a dead PID.
mkdir -p "$lockdir"
DEAD_PID=99999999   # extremely unlikely to be a live PID
echo "$DEAD_PID" > "$lockdir/pid"

if acquire_stack_lock "$STACK" "$TEST_ENV" 2>/dev/null; then
  pass "stale-PID broken and lock acquired"
else
  fail "stale-PID break failed — acquire returned non-zero"
fi

pid_in_file=$(cat "$lockdir/pid" 2>/dev/null || echo "")
if [ "$pid_in_file" = "$$" ]; then
  pass "PID file updated to current PID after stale break"
else
  fail "PID file is '$pid_in_file', expected $$ after stale break"
fi

release_stack_lock "$STACK" "$TEST_ENV"

# ---------------------------------------------------------------------------
# Scenario 5: path-traversal / invalid-name rejection
# ---------------------------------------------------------------------------
echo "--- Scenario 5: invalid stack names rejected ---"

# Representative bad names. Each must cause acquire AND release to return
# exit 1 BEFORE any filesystem effect. Empty string is handled by the
# "stack-name required" guard rather than the regex, but the outcome
# (return 1, no disk touch) is identical.
BAD_NAMES=(
  "../evil"
  "foo/bar"
  "/abs/path"
  ".."
  "with space"
  "pipe|name"
  "semi;colon"
)

for bad in "${BAD_NAMES[@]}"; do
  if acquire_stack_lock "$bad" "$TEST_ENV" 2>/dev/null; then
    fail "acquire_stack_lock accepted invalid name: '$bad'"
    release_stack_lock "$bad" "$TEST_ENV" 2>/dev/null || true
  else
    pass "acquire_stack_lock rejected invalid name: '$bad'"
  fi
  if release_stack_lock "$bad" "$TEST_ENV" 2>/dev/null; then
    fail "release_stack_lock accepted invalid name: '$bad'"
  else
    pass "release_stack_lock rejected invalid name: '$bad'"
  fi
done

# Verify no traversal artifact was created above the lock base.
if [ -e "$(dirname "$LOCK_BASE")/evil.lock.d" ] || [ -e "$LOCK_BASE/../evil.lock.d" ]; then
  fail "path-traversal artifact present on disk after rejection"
else
  pass "no path-traversal artifact left on disk"
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$TESTS_FAILED" -eq 0 ]; then
  echo "All stack-lock tests passed."
  exit 0
else
  echo "$TESTS_FAILED test(s) failed." >&2
  exit 1
fi
