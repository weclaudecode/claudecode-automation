#!/usr/bin/env bash
# Orchestrator tick — 5-phase dispatcher (Task 2.3.F).
#
# Run once per cron interval (or via /loop). Idempotent and
# self-terminating: every tick either advances state or no-ops.
#
# Tick phases:
#   0. Acquire lock, find the active plan's state file
#   1. refresh-deps    add orch:deps-met labels for ready issues
#   2. sweep-merges    transition tasks.N.status on merged/closed PRs
#   3. review-pass     (optional — only if review-pass.sh exists)
#   4. iterate-pass    (optional — only if iterate-pass.sh exists)
#   5. launch-pass     spawn up to MAX_PARALLEL workers on ready tasks
#   6. Plan-completion check: archive if all tasks terminal
#   7. Release lock
#
# Each phase is best-effort: a phase exit failure logs to stderr but
# does not abort the tick. Phases are sequential within a tick;
# parallelism (when enabled in 2.3.G) is *within* phase 5 only.

set -uo pipefail

REPO=$(git rev-parse --show-toplevel)
cd "$REPO"

# shellcheck source=.claude/scripts/_dispatcher_lib.sh
source "$REPO/.claude/scripts/_dispatcher_lib.sh"

LOCKDIR=".claude/state/orchestrator.lock"
LOG=".claude/state/orchestrator.log"
NOTIFY=".claude/scripts/notify.sh"
MAX_PARALLEL="${ORCH_MAX_PARALLEL:-1}"
LOG_MAX_BYTES="${ORCH_LOG_MAX_BYTES:-10485760}"  # 10 MiB default
# Auto-resolve toggle (Task 3.1). 0 = workers escalate on Tier-3 ambiguity
# (default); 1 = workers pick the recommended/defensible option and the PR
# reviewer's safety_block category becomes the gate. Per-plan frontmatter
# (state.auto_recommended) overrides this; see launch-worker.sh precedence.
AUTO_RECOMMENDED="${ORCH_AUTO_RECOMMENDED:-0}"
export ORCH_AUTO_RECOMMENDED="$AUTO_RECOMMENDED"

mkdir -p .claude/state .claude/plans/archive

# Combined cleanup for normal exit AND signal interruption.
# - Removes any worktrees still registered in the active manifest. Workers
#   that exited gracefully will have unregistered themselves; survivors
#   are leaks from workers killed mid-spawn.
# - Releases the global tick lock.
cleanup_tick() {
  cleanup_active_worktrees 2>/dev/null || true
  rm -rf "$LOCKDIR" 2>/dev/null
}

# Size-based log rotation
if [ -f "$LOG" ]; then
  size=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ' || echo 0)
  if [ "${size:-0}" -gt "$LOG_MAX_BYTES" ]; then
    mv "$LOG" "${LOG}.$(date -u +%Y%m%dT%H%M%SZ)"
  fi
fi

exec >> "$LOG" 2>&1
echo
echo "=== tick $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# ---- Phase 0: lock + state file lookup ----
# mkdir is atomic across macOS and Linux. Stale locks (script killed
# before trap fired) are broken by checking the recorded PID for liveness.
if mkdir "$LOCKDIR" 2>/dev/null; then
  echo $$ > "$LOCKDIR/pid"
  trap cleanup_tick EXIT INT TERM
else
  STALE_PID=$(cat "$LOCKDIR/pid" 2>/dev/null || echo "")
  if [ -n "$STALE_PID" ] && ! kill -0 "$STALE_PID" 2>/dev/null; then
    echo "stale lock from PID $STALE_PID — breaking"
    rm -rf "$LOCKDIR"
    if mkdir "$LOCKDIR" 2>/dev/null; then
      echo $$ > "$LOCKDIR/pid"
      trap cleanup_tick EXIT INT TERM
    else
      echo "lock race after stale-break, skipping"
      exit 0
    fi
  else
    echo "lock held by PID ${STALE_PID:-?}, skipping"
    exit 0
  fi
fi

# Proactive cleanup: a previously-SIGKILLed tick may have left a manifest
# behind (its trap never fired). Now that we own the lock, mop it up
# before any phase runs — otherwise the surviving worktrees pile up.
cleanup_active_worktrees 2>/dev/null || true

STATE_FILE=$(ls -t .claude/plans/*.state.json 2>/dev/null \
  | xargs -I {} sh -c 'jq -er ".status == \"in_progress\"" {} >/dev/null 2>&1 && echo {}' \
  | tail -1)

if [ -z "$STATE_FILE" ]; then
  echo "no active plan, idle"
  exit 0
fi

PLAN_FILE=$(jq -r '.plan_file' "$STATE_FILE")
TOTAL=$(jq -r '.total_tasks' "$STATE_FILE")
PLAN_BASE=$(basename "$PLAN_FILE" .md)
PLAN_NUM=$(echo "$PLAN_BASE" | grep -oE 'PLAN-[0-9]+' | grep -oE '[0-9]+' || echo "00")
REPO_OWNER_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)

if [ -z "$REPO_OWNER_REPO" ]; then
  echo "could not detect repo via gh; aborting tick"
  exit 1
fi

echo "plan: $PLAN_FILE  total: $TOTAL  max_parallel: $MAX_PARALLEL  auto_recommended: $AUTO_RECOMMENDED  repo: $REPO_OWNER_REPO"

# ---- Phase 1: refresh deps ----
echo "--- phase 1: refresh deps ---"
bash .claude/scripts/refresh-deps.sh "$STATE_FILE" "$REPO_OWNER_REPO" || \
  echo "warning: refresh-deps exited non-zero (continuing)" >&2

# ---- Phase 2: sweep merges ----
echo "--- phase 2: sweep merges ---"
bash .claude/scripts/sweep-merges.sh "$STATE_FILE" "$REPO_OWNER_REPO" || \
  echo "warning: sweep-merges exited non-zero (continuing)" >&2

# ---- Phase 3: review pass (optional) ----
if [ -x .claude/scripts/review-pass.sh ]; then
  echo "--- phase 3: review pass ---"
  bash .claude/scripts/review-pass.sh "$STATE_FILE" "$REPO_OWNER_REPO" || \
    echo "warning: review-pass exited non-zero (continuing)" >&2
fi

# ---- Phase 4: iterate pass (optional) ----
if [ -x .claude/scripts/iterate-pass.sh ]; then
  echo "--- phase 4: iterate pass ---"
  bash .claude/scripts/iterate-pass.sh "$STATE_FILE" "$REPO_OWNER_REPO" || \
    echo "warning: iterate-pass exited non-zero (continuing)" >&2
fi

# ---- Phase 5: launch pass ----
echo "--- phase 5: launch pass ---"
bash .claude/scripts/launch-pass.sh "$STATE_FILE" "$REPO_OWNER_REPO" "$MAX_PARALLEL" || \
  echo "warning: launch-pass exited non-zero (continuing)" >&2

# ---- Plan-completion check ----
# All tasks reached terminal status (merged | blocked) -> archive plan.
# Partial-blocked plans still archive — operator can rescue from archive/
# after fixing the upstream issue and re-ingesting.
ALL_TERMINAL=$(jq -r '[.tasks[] | select(.status != "merged" and .status != "blocked")] | length == 0' "$STATE_FILE" 2>/dev/null || echo "false")

if [ "$ALL_TERMINAL" = "true" ]; then
  MERGED_COUNT=$(jq -r '[.tasks[] | select(.status == "merged")] | length' "$STATE_FILE")
  BLOCKED_COUNT=$(jq -r '[.tasks[] | select(.status == "blocked")] | length' "$STATE_FILE")

  # Task 4.3: plan-level status reflects forward progress.
  # - any merged tasks  -> done   (partial-block plans still count as done)
  # - zero merged tasks -> blocked (no forward progress was possible)
  # Both still archive — operator can rescue from .claude/plans/archive/.
  if [ "$MERGED_COUNT" -eq 0 ]; then
    FINAL_STATUS="blocked"
  else
    FINAL_STATUS="done"
  fi

  echo "plan $PLAN_NUM terminal: $MERGED_COUNT merged, $BLOCKED_COUNT blocked; marking $FINAL_STATUS and archiving"

  state_write "$STATE_FILE" --arg s "$FINAL_STATUS" '.status = $s | .completed_at = (now | todateiso8601)' \
    || echo "warning: failed to mark plan $FINAL_STATUS in state file" >&2

  mv "$PLAN_FILE" .claude/plans/archive/ 2>/dev/null || \
    echo "warning: could not move plan file to archive (already moved?)" >&2
  mv "$STATE_FILE" .claude/plans/archive/ 2>/dev/null || \
    echo "warning: could not move state file to archive (already moved?)" >&2

  if [ "$FINAL_STATUS" = "blocked" ]; then
    bash "$NOTIFY" "plan $PLAN_NUM blocked" \
      "$BLOCKED_COUNT/$TOTAL tasks blocked, 0 merged. No forward progress. Archived; rescue from .claude/plans/archive/ to retry."
  elif [ "$BLOCKED_COUNT" -gt 0 ]; then
    bash "$NOTIFY" "plan $PLAN_NUM done with blocks" \
      "$MERGED_COUNT/$TOTAL merged, $BLOCKED_COUNT blocked. Archived; rescue from .claude/plans/archive/ to retry."
  else
    bash "$NOTIFY" "plan $PLAN_NUM done" "all $TOTAL tasks merged"
  fi
fi

echo "tick done"
