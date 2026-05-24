#!/usr/bin/env bash
# deploy-watch.sh — Phase 8 of the orchestrator tick.
#
# Watches disowned CDK deploys and transitions plan state when they finish.
#
# Usage: deploy-watch.sh
#   (no arguments; reads all .claude/state/<env>/deploy-status-*.json files)
#
# Migration note: pre-PLAN-05 installs wrote status files at the flat path
#   .claude/state/deploy-status-<task>.json
# The new env-namespaced path is:
#   .claude/state/<env>/deploy-status-<task>.json
# Existing flat files will NOT be picked up by the new glob. Operators should
# either move them manually (`mv .claude/state/deploy-status-*.json
# .claude/state/dev/`) or let them age out (they won't cause errors).
#
# ────────────────────────────────────────────────────────────────────────────
# WORKER-SIDE CONVENTION (for tasks with deploy_mode == "autonomous")
#
# When a worker handles a task with deploy_mode: autonomous, after the PR is
# green and merged, instead of running `cdk deploy` synchronously (which would
# exceed --max-turns), the worker should:
#
#   source "$REPO/.claude/scripts/_dispatcher_lib.sh"
#
#   # T12: stack locks are per-env. The worker must read its plan's env and
#   # pass it as the 2nd arg so the lock lands under .claude/state/<env>/.
#   # deploy-watch later reads env from the plan state file to release the
#   # matching lock — pass the SAME value here or the lock will be stranded.
#   TASK_ENV=$(jq -r '.env // "dev"' "$STATE_FILE")
#
#   acquire_stack_lock "$STACK" "$TASK_ENV" || {
#     echo "deploy: stack '$STACK' is already being deployed; aborting" >&2
#     exit 1
#   }
#
#   # The acquire records $$ (the worker's PID) in the lock file. Since the
#   # worker is about to exit, overwrite it with the "orchestrator:external"
#   # sentinel — release_stack_lock recognises this and relinquishes the lock
#   # without the usual "held by a different PID" warning. The disowned cdk
#   # process's PID lives in the deploy-status JSON instead.
#   REPO_ROOT=$(git rev-parse --show-toplevel)
#   echo "orchestrator:external" > "$REPO_ROOT/.claude/state/${TASK_ENV}/cdk-stack-locks/${STACK}.lock.d/pid"
#
#   # T12: status files are env-namespaced to avoid silent corruption when two
#   # concurrent plans (e.g. dev and staging) share a task number. Use the
#   # env-namespaced path below; deploy-watch globs .claude/state/*/deploy-status-*.json.
#   LOG=".claude/state/${TASK_ENV}/deploy-status-${TASK_NUM}.log"
#   mkdir -p ".claude/state/${TASK_ENV}"
#   nohup cdk deploy "$STACK" --require-approval never >"$LOG" 2>&1 &
#   DEPLOY_PID=$!
#   disown
#
#   # Write the env-namespaced status file that deploy-watch.sh will poll
#   cat > ".claude/state/${TASK_ENV}/deploy-status-${TASK_NUM}.json" <<EOF
#   {
#     "task": $TASK_NUM,
#     "plan": "$PLAN_ID",
#     "stack": "$STACK",
#     "pid": $DEPLOY_PID,
#     "log_file": "$LOG",
#     "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
#     "status": "running",
#     "pr": $PR_NUM,
#     "exit_code": null
#   }
#   EOF
#
#   # Worker exits — orchestrator deploy-watch picks up from here on the
#   # next tick(s) until the deploy finishes.
#
# deploy-watch releases the stack lock once the deploy reaches a terminal
# state (succeeded/failed/rolled_back). The sentinel pattern above avoids a
# spurious "held by different PID" warning at release time.
# ────────────────────────────────────────────────────────────────────────────
#
# Status file format (after deploy-watch updates it):
#   {
#     "task": <N>,
#     "plan": "<PLAN-ID>",
#     "stack": "<StackName>",
#     "pid": <N>,
#     "log_file": "<path>",
#     "started_at": "<iso8601>",
#     "status": "running" | "succeeded" | "failed",
#     "pr": <N> | null,
#     "exit_code": null | 0 | 1,
#     "finished_at": "<iso8601>",       -- added when terminal
#     "failure_reason": "<string>"      -- added on failure only
#   }
#
# Log-tail heuristic (used because exit code is unavailable for disowned processes):
#   Success indicators (any of):  "✅"  "deployed"  "deploy: complete"  "UPDATE_COMPLETE"
#   Failure indicators (any of):  "❌"  "Failed"  "Error"  "ROLLBACK"  "UPDATE_FAILED"
#   Ambiguous (neither matched):  marked failed with failure_reason="ambiguous_log_outcome"
#
# PR comment idempotency: deploy-watch posts a comment tagged <!-- deploy-watch -->
# and skips re-posting if that tag is already present in the PR's comments.
#
# Exit codes:
#   0  ran to completion (individual task errors are logged, not fatal)
#   1  hard environment failure (jq/gh missing, cannot source lib)

set -uo pipefail

command -v jq >/dev/null || { echo "deploy-watch: jq required" >&2; exit 1; }
command -v gh >/dev/null || { echo "deploy-watch: gh required" >&2; exit 1; }

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "deploy-watch: cannot determine repo root" >&2
  exit 1
}

# shellcheck source=_dispatcher_lib.sh
source "$REPO_ROOT/.claude/scripts/_dispatcher_lib.sh"

STATE_DIR="$REPO_ROOT/.claude/state"
# T12: status files live under .claude/state/<env>/deploy-status-<task>.json
# so that concurrent plans targeting dev vs staging never collide on the same
# file. Glob all env subdirs with a wildcard; this also picks up any future
# envs without code changes.
STATUS_GLOB="$STATE_DIR/*/deploy-status-*.json"

# Collect status files (glob; skip if none)
STATUS_FILES=()
for f in $STATUS_GLOB; do
  [ -f "$f" ] && STATUS_FILES+=("$f")
done

if [ "${#STATUS_FILES[@]}" -eq 0 ]; then
  echo "deploy-watch: no deploy status files found; nothing to do"
  exit 0
fi

# ---- Helpers ----

# iso8601 timestamp (UTC)
now_iso8601() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Detect outcome from the tail of a log file.
# Prints "succeeded", "failed", "rolled_back", or "ambiguous".
# Args: <log_file> <stack_name>
#
# Detection order matters: ROLLBACK indicators MUST be checked before
# generic success patterns, because CloudFormation's UPDATE_ROLLBACK_COMPLETE
# substring-matches UPDATE_COMPLETE — a partial deploy that rolled back would
# otherwise be silently classified as success and the task marked merged.
detect_log_outcome() {
  local log_file="$1"
  local stack="$2"

  if [ ! -f "$log_file" ]; then
    echo "ambiguous"
    return
  fi

  # Read last 50 lines of log for pattern matching
  local tail_content
  tail_content=$(tail -n 50 "$log_file" 2>/dev/null || echo "")

  # 1. Rollback FIRST — must precede the success check (see comment above).
  #    Covers UPDATE_ROLLBACK_COMPLETE, UPDATE_ROLLBACK_FAILED, ROLLBACK_COMPLETE,
  #    ROLLBACK_IN_PROGRESS, plus the human-readable "rolled back" variants.
  if echo "$tail_content" | grep -qiE 'ROLLBACK|rolled back|rolling back'; then
    echo "rolled_back"
    return
  fi

  # 2. Other failure patterns.
  if echo "$tail_content" | grep -qiE '❌|Failed|Error:|UPDATE_FAILED|CREATE_FAILED|DELETE_FAILED'; then
    echo "failed"
    return
  fi

  # 3. Success patterns (only reached if no rollback/failure indicators above).
  if echo "$tail_content" | grep -qiE '✅|deployed|deploy: complete|UPDATE_COMPLETE|CREATE_COMPLETE'; then
    echo "succeeded"
    return
  fi

  echo "ambiguous"
}

# Post a PR comment with the deploy summary. Idempotent — skips if
# <!-- deploy-watch --> tag already present in the PR's comments.
# Args: <pr_num> <task_num> <stack> <started_at> <finished_at> <outcome> <log_file>
post_pr_comment() {
  local pr_num="$1"
  local task_num="$2"
  local stack="$3"
  local started_at="$4"
  local finished_at="$5"
  local outcome="$6"
  local log_file="$7"

  # Check for existing deploy-watch comment (idempotency).
  local existing
  existing=$(gh pr view "$pr_num" --json comments -q '.comments[].body' 2>/dev/null \
    | grep -c '<!-- deploy-watch -->' || echo 0)

  if [ "${existing:-0}" -gt 0 ]; then
    echo "deploy-watch: task $task_num — PR #$pr_num already has a deploy-watch comment; skipping re-post"
    return 0
  fi

  local icon
  [ "$outcome" = "succeeded" ] && icon="✅" || icon="❌"

  # Capture last 30 lines of log for the comment body.
  local log_tail=""
  if [ -f "$log_file" ]; then
    log_tail=$(tail -n 30 "$log_file" 2>/dev/null || echo "(log unavailable)")
  else
    log_tail="(log file not found: $log_file)"
  fi

  local body_file
  body_file=$(mktemp "/tmp/deploy-watch-comment-XXXXXX.md")
  # shellcheck disable=SC2064
  trap "rm -f '$body_file'" RETURN

  cat > "$body_file" <<EOF
<!-- deploy-watch -->
## ${icon} CDK Deploy: \`${stack}\` — ${outcome}

| Field | Value |
|---|---|
| Stack | \`${stack}\` |
| Task | ${task_num} |
| Status | **${outcome}** |
| Started | ${started_at} |
| Finished | ${finished_at} |

<details>
<summary>Last 30 lines of deploy log</summary>

\`\`\`
${log_tail}
\`\`\`

</details>
EOF

  if gh pr comment "$pr_num" --body-file "$body_file" >/dev/null 2>&1; then
    echo "deploy-watch: task $task_num — posted deploy-watch comment on PR #$pr_num"
  else
    echo "deploy-watch: task $task_num — warning: failed to post comment on PR #$pr_num" >&2
  fi
}

# Find the active plan's state file (matches orchestrator.sh logic).
find_state_file() {
  ls -t "$REPO_ROOT/.claude/plans/"*.state.json 2>/dev/null \
    | while IFS= read -r f; do
        if jq -er '.status == "in_progress"' "$f" >/dev/null 2>&1; then
          echo "$f"
          return
        fi
      done \
    | head -1
}

# ---- Main loop ----

WATCHED=0
STILL_RUNNING=0
SETTLED=0
ERRORS=0

for status_file in "${STATUS_FILES[@]}"; do
  # Read fields from the status JSON.
  task_num=$(jq -r '.task' "$status_file" 2>/dev/null)
  plan_id=$(jq -r '.plan' "$status_file" 2>/dev/null)
  stack=$(jq -r '.stack' "$status_file" 2>/dev/null)
  pid=$(jq -r '.pid' "$status_file" 2>/dev/null)
  log_file=$(jq -r '.log_file' "$status_file" 2>/dev/null)
  cur_status=$(jq -r '.status' "$status_file" 2>/dev/null)
  started_at=$(jq -r '.started_at' "$status_file" 2>/dev/null)
  pr_num=$(jq -r '.pr // "null"' "$status_file" 2>/dev/null)

  # Validate required fields.
  if [ -z "$task_num" ] || [ "$task_num" = "null" ] \
     || [ -z "$stack" ] || [ "$stack" = "null" ] \
     || [ -z "$pid" ] || [ "$pid" = "null" ]; then
    echo "deploy-watch: malformed status file (missing task/stack/pid): $status_file" >&2
    ERRORS=$((ERRORS + 1))
    continue
  fi

  WATCHED=$((WATCHED + 1))

  # Skip already-settled entries (idempotency on re-runs).
  if [ "$cur_status" != "running" ]; then
    echo "deploy-watch: task $task_num — status is '$cur_status'; already settled, skipping"
    SETTLED=$((SETTLED + 1))
    continue
  fi

  # --- Check process liveness ---
  if kill -0 "$pid" 2>/dev/null; then
    echo "deploy-watch: task $task_num still running (PID $pid)" >&2
    STILL_RUNNING=$((STILL_RUNNING + 1))
    continue
  fi

  # Process is dead — determine outcome from log.
  outcome=$(detect_log_outcome "$log_file" "$stack")
  finished_at=$(now_iso8601)

  echo "deploy-watch: task $task_num — PID $pid dead; log outcome: $outcome"

  # Map outcome to exit_code and possibly a failure_reason.
  local_exit_code=1
  local_failure_reason=""
  case "$outcome" in
    succeeded)   local_exit_code=0 ;;
    rolled_back) local_failure_reason="rolled_back" ;;
    ambiguous)   local_failure_reason="ambiguous_log_outcome" ;;
    *)           : ;;  # failed — no extra reason, log tail tells the story
  esac

  # Update the deploy status file (not the plan state file — plain write is
  # fine here; this file is only read/written by deploy-watch itself).
  local_new_status="succeeded"
  [ "$outcome" != "succeeded" ] && local_new_status="failed"

  jq --arg s "$local_new_status" \
     --arg fin "$finished_at" \
     --argjson ec "$local_exit_code" \
     --arg fr "$local_failure_reason" \
     '.status = $s | .finished_at = $fin | .exit_code = $ec
      | if $fr != "" then .failure_reason = $fr else . end' \
     "$status_file" > "$status_file.tmp" 2>/dev/null \
  && mv "$status_file.tmp" "$status_file" \
  || {
    echo "deploy-watch: task $task_num — failed to update status file $status_file" >&2
    ERRORS=$((ERRORS + 1))
    rm -f "$status_file.tmp"
    continue
  }

  echo "deploy-watch: task $task_num — status file updated to '$local_new_status'"

  # --- Locate the plan state file (needed for both lock release env lookup
  #     AND the task-status update below). Done BEFORE release_stack_lock so
  #     the env is propagated correctly — T12 made stack locks per-env, and
  #     omitting env causes release to look at the wrong (default "dev") path.
  plan_state_file=""

  # Try the active plan first (most common case).
  active_state=$(find_state_file)
  if [ -n "$active_state" ]; then
    active_plan_base=$(basename "$(jq -r '.plan_file' "$active_state" 2>/dev/null)" .md)
    active_plan_id=$(echo "$active_plan_base" | grep -oE 'PLAN-[0-9]+' || echo "")
    if [ "$active_plan_id" = "$plan_id" ] || [ "$(basename "$active_state" .state.json)" = "$plan_id" ]; then
      plan_state_file="$active_state"
    fi
  fi

  # Fall back to searching all plans including archive.
  if [ -z "$plan_state_file" ]; then
    for sf in "$REPO_ROOT/.claude/plans/"*.state.json \
              "$REPO_ROOT/.claude/plans/archive/"*.state.json; do
      [ -f "$sf" ] || continue
      sf_base=$(basename "$sf" .state.json)
      if echo "$sf_base" | grep -q "$plan_id"; then
        plan_state_file="$sf"
        break
      fi
    done
  fi

  # --- Read env from the plan state file for stack-lock release.
  # T12: stack locks live at .claude/state/<env>/cdk-stack-locks/. The worker
  # acquired the lock with the plan's env, so the release MUST pass the same
  # env. If the state file is missing or has no env field, fall back to "dev"
  # — same default as acquire_stack_lock. A wrong env here strands the lock.
  task_env="dev"
  if [ -n "$plan_state_file" ] && [ -f "$plan_state_file" ]; then
    task_env=$(jq -r '.env // "dev"' "$plan_state_file" 2>/dev/null || echo "dev")
  fi

  # --- Release the stack lock (worker held it; we release it on completion) ---
  release_stack_lock "$stack" "$task_env" \
    || echo "deploy-watch: task $task_num — warning: could not release stack lock for '$stack' (env=$task_env)" >&2

  # --- Post PR comment if pr is not null ---
  if [ "$pr_num" != "null" ] && [ -n "$pr_num" ]; then
    post_pr_comment "$pr_num" "$task_num" "$stack" \
      "$started_at" "$finished_at" "$local_new_status" "$log_file"
  else
    echo "deploy-watch: task $task_num — no PR number; skipping comment"
  fi

  # --- Update the plan state file ---
  if [ -z "$plan_state_file" ]; then
    echo "deploy-watch: task $task_num — warning: could not find plan state file for plan '$plan_id'; skipping state update" >&2
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Write task state: merged on success, blocked on failure.
  if [ "$local_new_status" = "succeeded" ]; then
    if state_write "$plan_state_file" \
        '.tasks[$t].status = "merged" | .tasks[$t].merged_at = $fin' \
        --arg t "$task_num" --arg fin "$finished_at"; then
      echo "deploy-watch: task $task_num — plan state updated to 'merged'"
    else
      echo "deploy-watch: task $task_num — warning: state_write failed updating plan state to 'merged'" >&2
      ERRORS=$((ERRORS + 1))
    fi
  else
    if state_write "$plan_state_file" \
        '.tasks[$t].status = "blocked"
         | .tasks[$t].blocked_at = $fin
         | .tasks[$t].blocked_reason = "deploy_failed"' \
        --arg t "$task_num" --arg fin "$finished_at"; then
      echo "deploy-watch: task $task_num — plan state updated to 'blocked' (deploy_failed)"
    else
      echo "deploy-watch: task $task_num — warning: state_write failed updating plan state to 'blocked'" >&2
      ERRORS=$((ERRORS + 1))
    fi
  fi

done

echo "deploy-watch: done — watched=$WATCHED still_running=$STILL_RUNNING settled=$SETTLED errors=$ERRORS"
exit 0
