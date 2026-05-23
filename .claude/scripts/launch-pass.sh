#!/usr/bin/env bash
# Launch up to MAX_PARALLEL workers for ready tasks (dispatcher Phase 5).
#
# Usage: launch-pass.sh <state_file> <owner/repo> [<max_parallel>]
#
# Tick flow:
#   1. Count tasks already in_review.
#   2. Compute SLOTS = MAX_PARALLEL - in_review_count.
#   3. If SLOTS <= 0, no-op.
#   4. find-ready-tasks.sh emits up to SLOTS ready task numbers.
#   5. For each, spawn `launch-worker.sh` in the background.
#   6. wait on all spawned PIDs.
#
# MAX_PARALLEL defaults to 1 — preserves current sequential behavior.
# **Do NOT raise MAX_PARALLEL above 1 until Task 2.3.G ships atomic
# state.json writes via flock.** Concurrent launch-worker.sh instances
# will race on state.json updates and corrupt the file.
#
# Exit codes:
#   0  pass complete (zero or more workers spawned and all returned)
#   1  environment/args failure
#   N  bitwise-or of worker exit codes — actually: max worker exit
#      (we propagate the worst exit so the tick can react)

set -uo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <state_file> <owner/repo> [<max_parallel>]" >&2
  exit 1
fi

STATE_FILE="$1"
REPO="$2"
MAX_PARALLEL="${3:-${ORCH_MAX_PARALLEL:-1}}"

[ -f "$STATE_FILE" ] || { echo "launch-pass: state file not found: $STATE_FILE" >&2; exit 1; }
[[ "$MAX_PARALLEL" =~ ^[0-9]+$ ]] || { echo "launch-pass: max_parallel must be numeric, got '$MAX_PARALLEL'" >&2; exit 1; }

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "launch-pass: not inside a git work tree" >&2
  exit 1
}

FIND_READY="$REPO_ROOT/.claude/scripts/find-ready-tasks.sh"
LAUNCH_WORKER="${ORCH_LAUNCH_WORKER:-$REPO_ROOT/.claude/scripts/launch-worker.sh}"

[ -x "$FIND_READY" ] || {
  echo "launch-pass: find-ready-tasks.sh not executable at $FIND_READY" >&2
  exit 1
}
[ -x "$LAUNCH_WORKER" ] || {
  echo "launch-pass: launch-worker.sh not executable at $LAUNCH_WORKER" >&2
  exit 1
}

IN_REVIEW_COUNT=$(jq '[.tasks[] | select(.status == "in_review")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
SLOTS=$((MAX_PARALLEL - IN_REVIEW_COUNT))

if [ "$SLOTS" -le 0 ]; then
  echo "launch-pass: no slots (in_review=$IN_REVIEW_COUNT, max=$MAX_PARALLEL)"
  exit 0
fi

READY=$("$FIND_READY" "$STATE_FILE" "$SLOTS" "$REPO")
if [ -z "$READY" ]; then
  echo "launch-pass: no ready tasks (slots=$SLOTS)"
  exit 0
fi

# shellcheck disable=SC2206  # word-splitting is intentional — READY is newline-separated
READY_ARR=($READY)
echo "launch-pass: launching ${#READY_ARR[@]} task(s) (slots=$SLOTS): ${READY_ARR[*]}"

WORKER_PIDS=()
for task_num in "${READY_ARR[@]}"; do
  bash "$LAUNCH_WORKER" "$STATE_FILE" "$task_num" &
  WORKER_PIDS+=("$!")
done

# Wait on every spawned PID and track worst exit.
WORST_EXIT=0
for pid in "${WORKER_PIDS[@]}"; do
  if ! wait "$pid"; then
    EXIT=$?
    [ "$EXIT" -gt "$WORST_EXIT" ] && WORST_EXIT="$EXIT"
  fi
done

echo "launch-pass: done (workers=${#WORKER_PIDS[@]}, worst_exit=$WORST_EXIT)"
exit "$WORST_EXIT"
