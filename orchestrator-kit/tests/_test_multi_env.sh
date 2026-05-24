#!/usr/bin/env bash
# Unit tests for per-env lock namespacing (Task 12).
#
# Approach: directly test the helper functions from _dispatcher_lib.sh
# (get_orchestrator_lock_path, acquire_stack_lock with env arg) rather
# than running a full orchestrator.sh tick. Running the full tick would
# require a wired-up git repo with plans, gh auth, etc. The helper
# functions encapsulate all the per-env path logic, so unit-testing them
# gives the acceptance signal without the full integration overhead.
#
# Acceptance: two concurrent ticks for env:dev vs env:staging use
# independent lock paths and neither contends the other.
#
# Usage: bash orchestrator-kit/tests/_test_multi_env.sh
# Exit code: 0 = pass, 1 = any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$KIT_ROOT/.claude/scripts/_dispatcher_lib.sh"

TESTS_FAILED=0
fail() { echo "FAIL: $*" >&2; TESTS_FAILED=$((TESTS_FAILED + 1)); }
pass() { echo "PASS: $*"; }

cd "$KIT_ROOT" || exit 1
# shellcheck source=../orchestrator-kit/.claude/scripts/_dispatcher_lib.sh
source "$LIB"

REPO_ROOT=$(git rev-parse --show-toplevel)
STACK="multienv_test_$$"

cleanup() {
  rm -rf "$REPO_ROOT/.claude/state/dev/${STACK}.lock.d" 2>/dev/null || true
  rm -rf "$REPO_ROOT/.claude/state/staging/${STACK}.lock.d" 2>/dev/null || true
  rm -rf "$REPO_ROOT/.claude/state/dev/orchestrator.lock" 2>/dev/null || true
  rm -rf "$REPO_ROOT/.claude/state/staging/orchestrator.lock" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Scenario 1: get_orchestrator_lock_path returns correct env-namespaced path
# ---------------------------------------------------------------------------
echo "--- Scenario 1: get_orchestrator_lock_path ---"

dev_lock=$(get_orchestrator_lock_path "dev")
if [ "$dev_lock" = ".claude/state/dev/orchestrator.lock" ]; then
  pass "dev lock path: $dev_lock"
else
  fail "dev lock path wrong: got '$dev_lock', expected '.claude/state/dev/orchestrator.lock'"
fi

staging_lock=$(get_orchestrator_lock_path "staging")
if [ "$staging_lock" = ".claude/state/staging/orchestrator.lock" ]; then
  pass "staging lock path: $staging_lock"
else
  fail "staging lock path wrong: got '$staging_lock', expected '.claude/state/staging/orchestrator.lock'"
fi

default_lock=$(get_orchestrator_lock_path "")
if [ "$default_lock" = ".claude/state/dev/orchestrator.lock" ]; then
  pass "empty-env defaults to dev: $default_lock"
else
  fail "empty-env default wrong: got '$default_lock', expected '.claude/state/dev/orchestrator.lock'"
fi

# ---------------------------------------------------------------------------
# Scenario 2: dev and staging orchestrator lock paths are independent
# ---------------------------------------------------------------------------
echo "--- Scenario 2: independent orchestrator lock paths ---"

if [ "$dev_lock" != "$staging_lock" ]; then
  pass "dev and staging lock paths are distinct"
else
  fail "dev and staging lock paths are identical — not independent"
fi

# ---------------------------------------------------------------------------
# Scenario 3: stack locks are independent per env
# ---------------------------------------------------------------------------
echo "--- Scenario 3: stack locks are independent per env ---"

if acquire_stack_lock "$STACK" "dev"; then
  pass "acquired stack lock for env=dev"
else
  fail "could not acquire stack lock for env=dev"
fi

# Verify the lock landed in the dev namespace.
dev_stack_lock="$REPO_ROOT/.claude/state/dev/cdk-stack-locks/${STACK}.lock.d"
if [ -d "$dev_stack_lock" ]; then
  pass "dev stack lock dir exists at expected path"
else
  fail "dev stack lock dir missing at $dev_stack_lock"
fi

# Acquiring the same stack name for staging must succeed independently.
if acquire_stack_lock "$STACK" "staging"; then
  pass "acquired stack lock for env=staging (independent of dev)"
else
  fail "staging acquire failed — dev lock incorrectly blocked it"
fi

staging_stack_lock="$REPO_ROOT/.claude/state/staging/cdk-stack-locks/${STACK}.lock.d"
if [ -d "$staging_stack_lock" ]; then
  pass "staging stack lock dir exists at expected path"
else
  fail "staging stack lock dir missing at $staging_stack_lock"
fi

release_stack_lock "$STACK" "dev"
release_stack_lock "$STACK" "staging"

[ -d "$dev_stack_lock" ] && fail "dev stack lock lingers after release" || pass "dev stack lock released"
[ -d "$staging_stack_lock" ] && fail "staging stack lock lingers after release" || pass "staging stack lock released"

# ---------------------------------------------------------------------------
# Scenario 4: concurrent holds on same stack in different envs
# ---------------------------------------------------------------------------
echo "--- Scenario 4: concurrent same-stack holds across envs ---"

# Hold the dev lock in a background process; verify staging can still acquire.
bash -c "
  source '$LIB'
  acquire_stack_lock '$STACK' 'dev' >/dev/null 2>&1
  sleep 2
  release_stack_lock '$STACK' 'dev' >/dev/null 2>&1
" &
HOLDER_PID=$!
sleep 0.2

# Staging should acquire without contending the dev lock.
if acquire_stack_lock "$STACK" "staging"; then
  pass "staging acquire succeeded while dev is locked"
else
  fail "staging acquire failed — blocked by dev lock (incorrect contention)"
fi
release_stack_lock "$STACK" "staging"

# Also verify dev is still locked from our perspective (fail-fast).
if acquire_stack_lock "$STACK" "dev" 2>/dev/null; then
  fail "dev acquire succeeded while background holder is alive (should fail-fast)"
else
  pass "dev acquire correctly failed-fast while holder is alive"
fi

wait "$HOLDER_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Scenario 5: orchestrator lock mkdir — dev and staging paths both creatable
# ---------------------------------------------------------------------------
echo "--- Scenario 5: orchestrator lock directory creation ---"

dev_orch_lock=$(get_orchestrator_lock_path "dev")
staging_orch_lock=$(get_orchestrator_lock_path "staging")

mkdir -p "$(dirname "$REPO_ROOT/$dev_orch_lock")"
mkdir -p "$(dirname "$REPO_ROOT/$staging_orch_lock")"

if mkdir "$REPO_ROOT/$dev_orch_lock" 2>/dev/null; then
  pass "mkdir dev orchestrator lock succeeded"
else
  fail "mkdir dev orchestrator lock failed"
fi

if mkdir "$REPO_ROOT/$staging_orch_lock" 2>/dev/null; then
  pass "mkdir staging orchestrator lock succeeded (parallel with dev)"
else
  fail "mkdir staging orchestrator lock failed"
fi

rm -rf "${REPO_ROOT:?}/$dev_orch_lock" "${REPO_ROOT:?}/$staging_orch_lock"
pass "both orchestrator lock dirs cleaned up"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$TESTS_FAILED" -eq 0 ]; then
  echo "All multi-env tests passed."
  exit 0
else
  echo "$TESTS_FAILED test(s) failed." >&2
  exit 1
fi
