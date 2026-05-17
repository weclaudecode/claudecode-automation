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

mkdir -p .claude/state
exec >> "$LOG" 2>&1
echo
echo "=== tick $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# Lock — mkdir is atomic across macOS and Linux
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  echo "lock held, skipping"
  exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

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

if [ "$CURRENT" -gt "$TOTAL" ]; then
  echo "plan complete; archiving"
  jq '.status = "done" | .completed_at = (now | todateiso8601)' "$STATE_FILE" \
    > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  mv "$PLAN_FILE" .claude/plans/archive/ 2>/dev/null || true
  mv "$STATE_FILE" .claude/plans/archive/ 2>/dev/null || true
  bash "$NOTIFY" "plan $PLAN_NUM done" "all $TOTAL tasks merged"
  exit 0
fi

# Auto-merge policy for this task
AUTO_MERGE=$(jq -r --arg t "$CURRENT" '.auto_merge_overrides[$t] // true' "$STATE_FILE")
echo "auto-merge for task $CURRENT: $AUTO_MERGE"

# Worktree
BRANCH="claude/plan-${PLAN_NUM}-task-${CURRENT}"
WT="../wt-plan${PLAN_NUM}-t${CURRENT}"

# Clean any stale worktree from previous failed attempt
git worktree remove "$WT" --force 2>/dev/null || true

# Branch from latest main
git fetch origin main --quiet 2>/dev/null || true
git worktree add -B "$BRANCH" "$WT" origin/main 2>/dev/null \
  || git worktree add -B "$BRANCH" "$WT" main

cd "$WT"

# Worker prompt
WORKER_PROMPT_FILE="$REPO/.claude/prompts/worker-superpower.md"
RUN_OUT="$REPO/.claude/state/run-plan${PLAN_NUM}-t${CURRENT}.json"

echo "spawning worker..."

# Note: we do NOT --resume; each task gets a fresh context. opus[1m] for large
# codebases; drop to opus or sonnet to save quota if your repo is small.
# --max-turns bounds reviewer-iteration loops.
claude -p "$(cat "$WORKER_PROMPT_FILE")

## Active plan
$REPO/$PLAN_FILE

## Your assignment
Execute Task ${CURRENT} of ${TOTAL} from the plan above. Do not start any
other task. Mark each step's checkbox as you go. Commit at the end with
the message specified in the plan." \
  --permission-mode acceptEdits \
  --output-format json \
  --model "opus" \
  --max-turns 60 \
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
cd "$WT"
git push -u origin "$BRANCH" --quiet

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

# Auto-merge or label for review
cd "$REPO"
if [ "$AUTO_MERGE" = "true" ]; then
  gh pr merge "$PR_NUM" --auto --squash --delete-branch 2>&1 \
    && echo "auto-merge enabled on PR #$PR_NUM" \
    || echo "warning: --auto failed; PR will need manual merge"
else
  gh pr edit "$PR_NUM" --add-label "needs-robbie" 2>/dev/null || true
  bash "$NOTIFY" "PR needs review" "plan $PLAN_NUM task $CURRENT: $PR_URL"
  echo "labeled needs-robbie on PR #$PR_NUM"
fi

# Advance state
NEXT=$((CURRENT + 1))
jq ".current_task = $NEXT | .retries_for_current = 0" "$STATE_FILE" \
  > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

# Clean up worktree
git worktree remove "$WT" --force 2>/dev/null || true

echo "advanced to task $NEXT"
