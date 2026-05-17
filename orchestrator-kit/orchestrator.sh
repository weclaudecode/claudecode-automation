#!/usr/bin/env bash
# Orchestrator tick. Run once per cron interval (or via /loop).
#
# Each tick:
#   1. Acquire lock (mkdir-based, portable)
#   2. Find the active plan (oldest in_progress state file)
#   3. Read current task number
#   4. Create worktree on claude/plan-NN-task-M
#   5. Spawn fresh `claude -p` worker for that task only
#   6. On worker success: PR + auto-merge or label, advance state
#   7. On worker fail: increment retry; after 3, mark plan blocked + notify
#   8. Release lock

set -uo pipefail

REPO=$(git rev-parse --show-toplevel)
cd "$REPO"

LOCKDIR=".claude/state/orchestrator.lock"
LOG=".claude/state/orchestrator.log"
NOTIFY=".claude/scripts/notify.sh"
LOG_MAX_BYTES="${ORCH_LOG_MAX_BYTES:-10485760}"  # 10 MiB default

mkdir -p .claude/state
mkdir -p .claude/plans/archive

# Naive size-based log rotation: if log exceeds threshold, rename and start fresh.
if [ -f "$LOG" ]; then
  size=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ' || echo 0)
  if [ "${size:-0}" -gt "$LOG_MAX_BYTES" ]; then
    mv "$LOG" "${LOG}.$(date -u +%Y%m%dT%H%M%SZ)"
  fi
fi

exec >> "$LOG" 2>&1
echo
echo "=== tick $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# Lock — mkdir is atomic across macOS and Linux. Stale locks (script killed
# before trap fired) are detected by checking the recorded PID for liveness.
if mkdir "$LOCKDIR" 2>/dev/null; then
  echo $$ > "$LOCKDIR/pid"
  trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT
else
  STALE_PID=$(cat "$LOCKDIR/pid" 2>/dev/null || echo "")
  if [ -n "$STALE_PID" ] && ! kill -0 "$STALE_PID" 2>/dev/null; then
    echo "stale lock from PID $STALE_PID — breaking"
    rm -rf "$LOCKDIR"
    if mkdir "$LOCKDIR" 2>/dev/null; then
      echo $$ > "$LOCKDIR/pid"
      trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT
    else
      echo "lock race after stale-break, skipping"
      exit 0
    fi
  else
    echo "lock held by PID ${STALE_PID:-?}, skipping"
    exit 0
  fi
fi

# Find active plan state
STATE_FILE=$(ls -t .claude/plans/*.state.json 2>/dev/null \
  | xargs -I {} sh -c 'jq -er ".status == \"in_progress\"" {} >/dev/null 2>&1 && echo {}' \
  | tail -1)

if [ -z "$STATE_FILE" ]; then
  echo "no active plan, idle"
  exit 0
fi

PLAN_FILE=$(jq -r '.plan_file' "$STATE_FILE")
CURRENT=$(jq -r '.current_task' "$STATE_FILE")
TOTAL=$(jq -r '.total_tasks' "$STATE_FILE")
RETRIES=$(jq -r '.retries_for_current' "$STATE_FILE")
PLAN_BASE=$(basename "$PLAN_FILE" .md)
PLAN_NUM=$(echo "$PLAN_BASE" | grep -oE 'PLAN-[0-9]+' | grep -oE '[0-9]+' || echo "00")

echo "plan: $PLAN_FILE  task: $CURRENT/$TOTAL  retries: $RETRIES"

# Pending-PR gate: if a previous tick enabled --auto on a PR, wait for it to
# merge before starting the next task. Otherwise the next task branches off
# stale main and may produce code that conflicts with the pending merge.
PENDING=$(jq -r '.pending_pr // empty' "$STATE_FILE")
if [ -n "$PENDING" ]; then
  PR_STATE=$(gh pr view "$PENDING" --json state -q .state 2>/dev/null || echo UNKNOWN)
  case "$PR_STATE" in
    MERGED)
      echo "PR #$PENDING merged; clearing pending and advancing"
      jq 'del(.pending_pr) | .current_task += 1 | .retries_for_current = 0' \
        "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
      CURRENT=$(jq -r '.current_task' "$STATE_FILE")
      RETRIES=0
      ;;
    CLOSED)
      echo "PR #$PENDING closed unmerged — blocking plan"
      bash "$NOTIFY" "PR #$PENDING closed" \
        "plan $PLAN_NUM stuck; investigate before resuming"
      jq '.status = "blocked" | .blocked_at = (now | todateiso8601)' \
        "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
      exit 1
      ;;
    *)
      echo "waiting on PR #$PENDING (state=$PR_STATE)"
      exit 0
      ;;
  esac
fi

if [ "$CURRENT" -gt "$TOTAL" ]; then
  echo "plan complete; archiving"
  jq '.status = "done" | .completed_at = (now | todateiso8601)' "$STATE_FILE" \
    > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  mv "$PLAN_FILE" .claude/plans/archive/
  mv "$STATE_FILE" .claude/plans/archive/
  bash "$NOTIFY" "plan $PLAN_NUM done" "all $TOTAL tasks merged"
  exit 0
fi

# Per-task body lives in launch-worker.sh (Task 2.3.A extract). Same v1
# schema, same control flow — pure refactor for now. The 5-phase dispatcher
# (Task 2.3.F) will replace this single call with parallel launches.
bash .claude/scripts/launch-worker.sh "$STATE_FILE" "$CURRENT"
LAUNCH_EXIT=$?
echo "tick done (task $CURRENT, launch-worker exit=$LAUNCH_EXIT)"
exit $LAUNCH_EXIT
