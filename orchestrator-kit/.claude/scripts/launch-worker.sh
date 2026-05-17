#!/usr/bin/env bash
# Launch a worker for one task of an in-progress plan.
#
# Usage: launch-worker.sh <state_file> <task_num>
#
# Extracted verbatim from orchestrator.sh's per-task body (Phase 2 Task 2.3.A).
# Pure refactor — same v1 state schema (`current_task`, `retries_for_current`,
# `pending_pr`, `auto_merge_overrides`), same control flow, same exit codes.
# The dispatcher rewrite (sub-tasks 2.3.E/F) converts this to v2.
#
# Effects (on success):
#   - Pushes branch claude/plan-NN-task-M
#   - Opens PR via gh
#   - Auto-merge enabled → writes state.pending_pr = <PR#>, resets retries
#   - Sensitive (auto-merge disabled) → advances state.current_task, resets retries
#
# Effects (on failure):
#   - Worker exit non-zero → increments state.retries_for_current
#   - 3rd consecutive retry → sets state.status = "blocked"
#   - Push or PR-create failure → preserves worktree + state for retry
#
# Exit codes:
#   0  task advanced (state mutated, lock can be released)
#   1  hard failure (state may or may not be mutated; see notes above)

set -uo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <state_file> <task_num>" >&2
  exit 1
fi

STATE_FILE="$1"
CURRENT="$2"

[ -f "$STATE_FILE" ] || { echo "launch-worker: state file not found: $STATE_FILE" >&2; exit 1; }
[[ "$CURRENT" =~ ^[0-9]+$ ]] || { echo "launch-worker: task_num must be numeric, got '$CURRENT'" >&2; exit 1; }

REPO=$(git rev-parse --show-toplevel) || { echo "launch-worker: not inside a git work tree" >&2; exit 1; }
cd "$REPO" || { echo "launch-worker: cd to repo root failed" >&2; exit 1; }

NOTIFY=".claude/scripts/notify.sh"

# Read plan-level state. Same field names as v1 schema.
PLAN_FILE=$(jq -r '.plan_file' "$STATE_FILE")
TOTAL=$(jq -r '.total_tasks' "$STATE_FILE")
RETRIES=$(jq -r '.retries_for_current // 0' "$STATE_FILE")
PLAN_BASE=$(basename "$PLAN_FILE" .md)
PLAN_NUM=$(echo "$PLAN_BASE" | grep -oE 'PLAN-[0-9]+' | grep -oE '[0-9]+' || echo "00")

# Auto-merge policy for this task
AUTO_MERGE=$(jq -r --arg t "$CURRENT" '.auto_merge_overrides[$t] // true' "$STATE_FILE")
echo "launch-worker: task=$CURRENT/$TOTAL retries=$RETRIES auto-merge=$AUTO_MERGE"

# Worktree
BRANCH="claude/plan-${PLAN_NUM}-task-${CURRENT}"
WT="../wt-plan${PLAN_NUM}-t${CURRENT}"

# Clean any stale worktree from previous failed attempt
git worktree remove "$WT" --force 2>/dev/null || true

# Branch from latest main
git fetch origin main --quiet 2>/dev/null || true
git worktree add -B "$BRANCH" "$WT" origin/main 2>/dev/null \
  || git worktree add -B "$BRANCH" "$WT" main \
  || { echo "worktree add failed for $BRANCH at $WT"; exit 1; }

cd "$WT" || { echo "cd to worktree $WT failed"; exit 1; }

# Worker prompt
WORKER_PROMPT_FILE="$REPO/.claude/prompts/worker-superpower.md"
RUN_OUT="$REPO/.claude/state/run-plan${PLAN_NUM}-t${CURRENT}-r${RETRIES}.json"

# Pre-extract the task section so the worker doesn't need to read the whole
# plan file (saves tokens on long plans). Fence-aware so `## Task` literals
# inside code blocks don't break the boundary.
TASK_CONTENT=$(awk -v task="## Task ${CURRENT}:" '
  /^```/ { in_fence = !in_fence; if (found) print; next }
  in_fence { if (found) print; next }
  $0 ~ "^" task {found=1; print; next}
  found && /^## Task / {exit}
  found && /^## / && !/^## Task / {exit}
  found {print}
' "$REPO/$PLAN_FILE")

if [ -z "$TASK_CONTENT" ]; then
  echo "could not extract Task $CURRENT from $PLAN_FILE; aborting"
  exit 1
fi

# Cost knobs. Sonnet is the default — opt into opus per-plan when needed.
WORKER_MODEL="${ORCH_WORKER_MODEL:-sonnet}"
MAX_TURNS="${ORCH_MAX_TURNS:-30}"

echo "spawning worker (model=$WORKER_MODEL, max-turns=$MAX_TURNS)..."

# Note: we do NOT --resume; each task gets a fresh context.
# --max-turns bounds reviewer-iteration loops.
claude -p "$(cat "$WORKER_PROMPT_FILE")

## Active plan path (for cross-references only — task content is below)
$REPO/$PLAN_FILE

## Your assignment

Execute Task ${CURRENT} of ${TOTAL}. The full task spec follows verbatim. Do
not start any other task. Mark each step's checkbox as you go. Commit at the
end with the message specified in the task.

### Task ${CURRENT} (verbatim from plan)

${TASK_CONTENT}" \
  --permission-mode acceptEdits \
  --output-format json \
  --model "$WORKER_MODEL" \
  --max-turns "$MAX_TURNS" \
  > "$RUN_OUT"
WORKER_EXIT=$?

cd "$REPO"

if [ $WORKER_EXIT -ne 0 ]; then
  NEW_RETRIES=$((RETRIES + 1))
  echo "worker exited $WORKER_EXIT; retry $NEW_RETRIES/3"
  if [ "$NEW_RETRIES" -ge 3 ]; then
    jq '.status = "blocked" | .blocked_at = (now | todateiso8601)' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    bash "$NOTIFY" "plan $PLAN_NUM blocked" \
      "task $CURRENT failed 3 times. Investigate $RUN_OUT and worktree $WT"
    exit 1
  else
    jq ".retries_for_current = $NEW_RETRIES" "$STATE_FILE" \
      > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    # Keep the worktree for inspection on retry
    exit 0
  fi
fi

echo "worker succeeded"

# Push the branch and open PR
cd "$WT" || { echo "cd to worktree $WT failed before push"; exit 1; }
if ! git push -u origin "$BRANCH" --quiet 2> /tmp/orch-push.$$.err; then
  PUSH_ERR=$(cat /tmp/orch-push.$$.err 2>/dev/null || echo "")
  rm -f /tmp/orch-push.$$.err
  echo "git push failed: $PUSH_ERR"
  bash "$NOTIFY" "push failed" \
    "plan $PLAN_NUM task $CURRENT — auth or network. State NOT advanced; next tick will retry."
  cd "$REPO"
  # Preserve worktree and state. Operator fixes auth, next tick retries the
  # push. No retry counter increment — push failures aren't worker-quality issues.
  exit 1
fi
rm -f /tmp/orch-push.$$.err

# Pull summary from worker output for PR description
SUMMARY=$(jq -r '.result // empty' "$RUN_OUT" 2>/dev/null \
  | sed -n 's/.*"summary"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)
[ -z "$SUMMARY" ] && SUMMARY="Plan ${PLAN_NUM} / Task ${CURRENT} (auto)"

PR_BODY="$SUMMARY

---
- Plan: $PLAN_FILE
- Task: $CURRENT of $TOTAL
- Branch: $BRANCH
- Auto-merge: $AUTO_MERGE
- Run output: \`$RUN_OUT\`"

PR_URL=$(gh pr create \
  --title "[plan-${PLAN_NUM}/t${CURRENT}] $SUMMARY" \
  --body "$PR_BODY" \
  --head "$BRANCH" \
  --base main 2>&1) || {
    echo "gh pr create failed: $PR_URL"
    bash "$NOTIFY" "PR creation failed" "plan $PLAN_NUM task $CURRENT — investigate"
    exit 1
  }

PR_NUM=$(echo "$PR_URL" | grep -oE '[0-9]+$' | tail -1)
echo "PR opened: $PR_URL"

# Auto-merge or label for review.
# When auto-merge is enabled we DO NOT advance state — instead we record the
# PR number as pending. The next tick gates on its merge state before picking
# up the next task, so dependent tasks never branch from stale main.
cd "$REPO"
if [ "$AUTO_MERGE" = "true" ]; then
  if gh pr merge "$PR_NUM" --auto --squash --delete-branch 2>&1; then
    echo "auto-merge enabled on PR #$PR_NUM; will advance after merge"
    jq --argjson pr "$PR_NUM" '.pending_pr = $pr | .retries_for_current = 0' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  else
    echo "--auto failed on PR #$PR_NUM; treating as needs-review"
    gh pr edit "$PR_NUM" --add-label "needs-robbie" 2>/dev/null || true
    bash "$NOTIFY" "auto-merge failed" \
      "plan $PLAN_NUM task $CURRENT: $PR_URL — needs manual merge"
    # Advance anyway: subsequent tasks aren't blocked by a manually-merged PR
    # (the operator will handle it). If they ARE blocked, mark plan as
    # blocked manually and resume after merging.
    jq ".current_task = $((CURRENT + 1)) | .retries_for_current = 0" \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi
else
  gh pr edit "$PR_NUM" --add-label "needs-robbie" 2>/dev/null || true
  bash "$NOTIFY" "PR needs review" "plan $PLAN_NUM task $CURRENT: $PR_URL"
  echo "labeled needs-robbie on PR #$PR_NUM"
  # Sensitive-flagged tasks: advance state immediately so subsequent
  # non-sensitive tasks can proceed in parallel review queues. The operator
  # will manually merge in the right order.
  jq ".current_task = $((CURRENT + 1)) | .retries_for_current = 0" \
    "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
fi

# Clean up worktree
git worktree remove "$WT" --force 2>/dev/null || true

echo "launch-worker: done (task $CURRENT)"
