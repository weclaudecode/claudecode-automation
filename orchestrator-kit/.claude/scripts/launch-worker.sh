#!/usr/bin/env bash
# Launch a worker for one task of an in-progress plan.
#
# Usage: launch-worker.sh <state_file> <task_num>
#
# Per-task body of the dispatcher's Phase 5 (launch pass). Originally
# extracted from orchestrator.sh in Task 2.3.A; rewritten for the v2
# state schema in Task 2.3.F.
#
# Reads from state.tasks.N:
#   .retries           current retry count for this task
#   .issue             optional issue number (informational)
#
# Reads top-level state:
#   .plan_file         path to the plan markdown
#   .total_tasks       count, for log messages
#   .auto_merge_overrides[N]  if false, skip `gh pr merge --auto`
#
# Writes to state.tasks.N (atomic via temp+mv):
#   on worker non-zero exit (retries < 3) -> .retries++
#   on worker non-zero exit (retries == 3) -> .status = "blocked", .blocked_*
#   on PR opened (auto-merge OR sensitive) -> .status = "in_review", .pr = N
#
# After this script returns, sweep-merges.sh is the script that
# transitions in_review -> merged or blocked on PR state change.
#
# Concurrency note: with MAX_PARALLEL > 1, multiple launch-worker.sh
# instances can race on state.json writes. The flock fence lands in
# Task 2.3.G — until then, keep MAX_PARALLEL=1.
#
# Exit codes:
#   0  task launched (PR opened, state updated) OR retry recorded (worker failed but < 3 retries)
#   1  hard failure (worker hit 3 retries, push failed, or PR-create failed)

set -uo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <state_file> <task_num>" >&2
  exit 1
fi

RAW_STATE_FILE="$1"
TASK_NUM="$2"

[ -f "$RAW_STATE_FILE" ] || { echo "launch-worker: state file not found: $RAW_STATE_FILE" >&2; exit 1; }
[[ "$TASK_NUM" =~ ^[0-9]+$ ]] || { echo "launch-worker: task_num must be numeric, got '$TASK_NUM'" >&2; exit 1; }

REPO=$(git rev-parse --show-toplevel) || { echo "launch-worker: not inside a git work tree" >&2; exit 1; }
cd "$REPO" || { echo "launch-worker: cd to repo root failed" >&2; exit 1; }

# shellcheck source=_dispatcher_lib.sh
source "$REPO/.claude/scripts/_dispatcher_lib.sh"

# Resolve state file to absolute path. The script `cd`s into the worktree
# mid-run; relative paths break subsequent jq reads/writes.
case "$RAW_STATE_FILE" in
  /*) STATE_FILE="$RAW_STATE_FILE" ;;
  *)  STATE_FILE="$REPO/$RAW_STATE_FILE" ;;
esac

NOTIFY=".claude/scripts/notify.sh"

# v2 schema check
jq -e --arg t "$TASK_NUM" '.tasks[$t] | type == "object"' "$STATE_FILE" >/dev/null 2>&1 || {
  echo "launch-worker: task $TASK_NUM missing from state .tasks (state may be v1)" >&2
  exit 1
}

PLAN_FILE=$(jq -r '.plan_file' "$STATE_FILE")
TOTAL=$(jq -r '.total_tasks' "$STATE_FILE")
RETRIES=$(jq -r --arg t "$TASK_NUM" '.tasks[$t].retries // 0' "$STATE_FILE")
PLAN_BASE=$(basename "$PLAN_FILE" .md)
PLAN_NUM=$(echo "$PLAN_BASE" | grep -oE 'PLAN-[0-9]+' | grep -oE '[0-9]+' || echo "00")

AUTO_MERGE=$(jq -r --arg t "$TASK_NUM" '.auto_merge_overrides[$t] // true' "$STATE_FILE")

# Auto-recommended precedence: state.auto_recommended (per-plan) > env var > 0.
# Per-plan override (Task 3.4) lets an operator opt one experimental plan
# into auto-resolve without flipping the global ORCH_AUTO_RECOMMENDED.
#
# Use `has(...)` rather than `// empty`: jq's `//` triggers on `false` as
# well as `null`, which would silently drop a per-plan `false` and let the
# env var leak through.
PLAN_AUTO_REC=$(jq -r 'if has("auto_recommended") then .auto_recommended else "" end' "$STATE_FILE")
case "$PLAN_AUTO_REC" in
  true)  AUTO_RECOMMENDED=1 ;;
  false) AUTO_RECOMMENDED=0 ;;
  "")    AUTO_RECOMMENDED="${ORCH_AUTO_RECOMMENDED:-0}" ;;
  *)
    echo "launch-worker: invalid state.auto_recommended '$PLAN_AUTO_REC' (expected true|false); falling back to env" >&2
    AUTO_RECOMMENDED="${ORCH_AUTO_RECOMMENDED:-0}"
    ;;
esac

echo "launch-worker: task=$TASK_NUM/$TOTAL retries=$RETRIES auto-merge=$AUTO_MERGE auto-recommended=$AUTO_RECOMMENDED"

# Atomic state write helper — delegates to lib (mkdir-based lock makes
# this safe with MAX_PARALLEL > 1).
update_state() {
  local jq_expr="$1"
  if state_write "$STATE_FILE" "$jq_expr" --arg t "$TASK_NUM"; then
    return 0
  fi
  echo "launch-worker: state_write failed for task $TASK_NUM (jq or lock)" >&2
  return 1
}

# Worktree
BRANCH="claude/plan-${PLAN_NUM}-task-${TASK_NUM}"
WT="../wt-plan${PLAN_NUM}-t${TASK_NUM}"

git worktree remove "$WT" --force 2>/dev/null || true

git fetch origin main --quiet 2>/dev/null || true
git worktree add -B "$BRANCH" "$WT" origin/main 2>/dev/null \
  || git worktree add -B "$BRANCH" "$WT" main \
  || { echo "worktree add failed for $BRANCH at $WT"; exit 1; }

# Register before any work begins. Every graceful exit path below must
# unregister; signal-induced exits skip it so the orchestrator trap cleans.
register_worktree "$WT"

cd "$WT" || {
  echo "cd to worktree $WT failed"
  unregister_worktree "$WT"
  exit 1
}

WORKER_PROMPT_FILE="$REPO/.claude/prompts/worker-superpower.md"
RUN_OUT="$REPO/.claude/state/run-plan${PLAN_NUM}-t${TASK_NUM}-r${RETRIES}.json"

# Pre-extract the task section so the worker doesn't need to read the whole
# plan file. Fence-aware so `## Task` literals in code blocks don't break
# the boundary. Same pattern as ingest-plan.sh / create-issues.sh.
TASK_CONTENT=$(awk -v task="## Task ${TASK_NUM}:" '
  /^```/ { in_fence = !in_fence; if (found) print; next }
  in_fence { if (found) print; next }
  $0 ~ "^" task {found=1; print; next}
  found && /^## Task / {exit}
  found && /^## / && !/^## Task / {exit}
  found {print}
' "$REPO/$PLAN_FILE")

if [ -z "$TASK_CONTENT" ]; then
  echo "could not extract Task $TASK_NUM from $PLAN_FILE; aborting"
  exit 1
fi

WORKER_MODEL="${ORCH_WORKER_MODEL:-sonnet}"

# 5.7a: precedence per-task plan value > $ORCH_MAX_TURNS env > default 30.
# Use has() rather than `// 30` because jq's // triggers on 0 as well as
# null, which would silently drop a deliberate max_turns:0 (degenerate but
# still a real value). Same jq-falsy trap documented at line 84.
PER_TASK_MAX_TURNS=$(jq -r --arg t "$TASK_NUM" \
  'if (.tasks[$t] // {}) | has("max_turns") then .tasks[$t].max_turns else "" end' \
  "$STATE_FILE")
MAX_TURNS="${PER_TASK_MAX_TURNS:-${ORCH_MAX_TURNS:-30}}"
WORKER_TIMEOUT="${ORCH_WORKER_TIMEOUT:-600}"
TIMEOUT_CMD=$(find_timeout_cmd)

WORKER_FULL_PROMPT="$(cat "$WORKER_PROMPT_FILE")

## Active plan path (for cross-references only — task content is below)
$REPO/$PLAN_FILE

## Your assignment

AUTO_RECOMMENDED=${AUTO_RECOMMENDED}

Execute Task ${TASK_NUM} of ${TOTAL}. The full task spec follows verbatim. Do
not start any other task. Mark each step's checkbox as you go. Commit at the
end with the message specified in the task.

### Task ${TASK_NUM} (verbatim from plan)

${TASK_CONTENT}"

# Build invocation as array so the timeout prefix is optional without
# duplicating the claude command. Exit 124 from `timeout` means the worker
# was killed — naturally treated as a non-zero WORKER_EXIT and counted as
# a retry, same as any other failure.
RUN_CMD=()
if [ -n "$TIMEOUT_CMD" ]; then
  RUN_CMD=("$TIMEOUT_CMD" "${WORKER_TIMEOUT}s")
  echo "spawning worker (model=$WORKER_MODEL, max-turns=$MAX_TURNS, timeout=${WORKER_TIMEOUT}s)..."
else
  echo "spawning worker (model=$WORKER_MODEL, max-turns=$MAX_TURNS, timeout=NONE — install coreutils/gtimeout)..."
fi
RUN_CMD+=(claude -p "$WORKER_FULL_PROMPT"
  --permission-mode bypassPermissions
  --output-format json
  --model "$WORKER_MODEL"
  --max-turns "$MAX_TURNS")

"${RUN_CMD[@]}" > "$RUN_OUT"
WORKER_EXIT=$?
if [ "$WORKER_EXIT" = "124" ] && [ -n "$TIMEOUT_CMD" ]; then
  echo "worker exceeded ${WORKER_TIMEOUT}s timeout — counted as failure"
fi

cd "$REPO"

if [ $WORKER_EXIT -ne 0 ]; then
  NEW_RETRIES=$((RETRIES + 1))
  echo "worker exited $WORKER_EXIT; retry $NEW_RETRIES/3"
  if [ "$NEW_RETRIES" -ge 3 ]; then
    update_state '.tasks[$t].status = "blocked" | .tasks[$t].retries = 3 | .tasks[$t].blocked_at = (now | todateiso8601) | .tasks[$t].blocked_reason = "worker_failed_3x"'
    # 5.7b: cascade-block transitive pending dependents so the plan can
    # archive instead of looping forever on tasks whose dep will never close.
    cascade_block "$STATE_FILE" "$TASK_NUM" || true
    bash "$NOTIFY" "plan $PLAN_NUM task $TASK_NUM blocked" \
      "Worker failed 3 times. Investigate $RUN_OUT and worktree $WT"
    # Worktree intentionally preserved for human inspection; unregister so
    # the orchestrator's trap does not auto-remove it.
    unregister_worktree "$WT"
    exit 1
  else
    update_state ".tasks[\$t].retries = $NEW_RETRIES"
    # Keep the worktree for inspection on retry; unregister for same reason
    # as the hard-block path above.
    unregister_worktree "$WT"
    exit 0
  fi
fi

echo "worker succeeded"

cd "$WT" || { echo "cd to worktree $WT failed before push"; unregister_worktree "$WT"; exit 1; }
if ! git push -u origin "$BRANCH" --quiet 2> /tmp/orch-push.$$.err; then
  PUSH_ERR=$(cat /tmp/orch-push.$$.err 2>/dev/null || echo "")
  rm -f /tmp/orch-push.$$.err
  echo "git push failed: $PUSH_ERR"
  bash "$NOTIFY" "push failed" \
    "plan $PLAN_NUM task $TASK_NUM — auth or network. State NOT advanced; next tick will retry."
  cd "$REPO"
  # Preserve worktree and state. Operator fixes auth, next tick retries.
  unregister_worktree "$WT"
  exit 1
fi
rm -f /tmp/orch-push.$$.err

# PR summary
SUMMARY=$(jq -r '.[] | select(.type == "result") | .result // empty' "$RUN_OUT" 2>/dev/null \
  | sed -n 's/.*"summary"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)
[ -z "$SUMMARY" ] && SUMMARY="Plan ${PLAN_NUM} / Task ${TASK_NUM} (auto)"

# 5.7c: cap title at 80 chars; full summary stays in the body. Workers
# routinely emit 200-400 char summaries, which makes the PR list unreadable.
SUMMARY_TITLE="${SUMMARY:0:80}"
[ "${#SUMMARY}" -gt 80 ] && SUMMARY_TITLE="${SUMMARY_TITLE}…"

ISSUE_NUM=$(jq -r --arg t "$TASK_NUM" '.tasks[$t].issue // empty' "$STATE_FILE")
CLOSES_LINE=""
[ -n "$ISSUE_NUM" ] && CLOSES_LINE="Closes #${ISSUE_NUM}"

PR_BODY="$SUMMARY

---
- Plan: $PLAN_FILE
- Task: $TASK_NUM of $TOTAL
- Branch: $BRANCH
- Auto-merge: $AUTO_MERGE
- Run output: \`$RUN_OUT\`
$CLOSES_LINE"

PR_URL=$(gh pr create \
  --title "[plan-${PLAN_NUM}/t${TASK_NUM}] $SUMMARY_TITLE" \
  --body "$PR_BODY" \
  --head "$BRANCH" \
  --base main 2>&1) || {
    echo "gh pr create failed: $PR_URL"
    bash "$NOTIFY" "PR creation failed" "plan $PLAN_NUM task $TASK_NUM — investigate"
    unregister_worktree "$WT"
    exit 1
  }

PR_NUM=$(echo "$PR_URL" | grep -oE '[0-9]+$' | tail -1)
echo "PR opened: $PR_URL"

cd "$REPO"

# Record PR + transition pending -> in_review. Both code paths land here.
if ! update_state ".tasks[\$t].status = \"in_review\" | .tasks[\$t].pr = $PR_NUM | .tasks[\$t].retries = 0"; then
  echo "launch-worker: state update failed AFTER PR was opened — manual reconcile required" >&2
  unregister_worktree "$WT"
  exit 1
fi

if [ "$AUTO_MERGE" = "true" ]; then
  if gh pr merge "$PR_NUM" --auto --squash --delete-branch 2>&1; then
    echo "auto-merge enabled on PR #$PR_NUM; sweep-merges will pick up on next tick"
  else
    echo "--auto failed on PR #$PR_NUM; treating as needs-review"
    gh pr edit "$PR_NUM" --add-label "orch:needs-robbie" 2>/dev/null || true
    bash "$NOTIFY" "auto-merge failed" \
      "plan $PLAN_NUM task $TASK_NUM: $PR_URL — needs manual merge"
  fi
else
  gh pr edit "$PR_NUM" --add-label "orch:needs-robbie" 2>/dev/null || true
  bash "$NOTIFY" "PR needs review" "plan $PLAN_NUM task $TASK_NUM: $PR_URL"
  echo "labeled orch:needs-robbie on PR #$PR_NUM"
fi

git worktree remove "$WT" --force 2>/dev/null || true
unregister_worktree "$WT"

echo "launch-worker: done (task $TASK_NUM, PR #$PR_NUM, status=in_review)"
