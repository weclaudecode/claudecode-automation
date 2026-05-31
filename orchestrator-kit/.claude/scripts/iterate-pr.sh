#!/usr/bin/env bash
# Per-task iteration runner for the dispatcher's Phase 4 (iterate pass).
#
# Usage: iterate-pr.sh <state_file> <task_num>
#
# Re-spawns a worker against a PR that has accumulated reviewer
# change-requests. The worker checks out the PR's existing branch (NOT a
# fresh branch off main), addresses the latest CHANGES_REQUESTED review's
# findings, commits, and exits. This script then pushes the new commits;
# review-pass + sweep-merges handle the subsequent transitions.
#
# Reads from state.tasks.N:
#   .pr                current PR number (REQUIRED — task must be in_review)
#   .retries           current retry count for THIS iteration round
#
# Reads top-level state:
#   .plan_file         path to the plan markdown (for task spec extract)
#   .total_tasks       count, for log messages
#
# Reads from PR body:
#   <!-- orch:review-iter:N -->   prior iteration count
#
# Writes to state.tasks.N (atomic via temp+mv):
#   on iter cap hit -> .status = "blocked", .blocked_reason = "review_iter_cap"
#   on worker non-zero (retries < 3) -> .retries++
#   on worker non-zero (retries == 3) -> .status = "blocked", .blocked_reason = "iterate_failed_3x"
#   on worker success -> .retries = 0 (status stays "in_review")
#
# Hard invariants:
#   - Never resets the PR branch (uses `git worktree add` with a checkout,
#     no `-B` flag). Rewriting an open PR's history would invalidate the
#     reviewer's anchor SHAs and confuse the next review pass.
#   - Never creates a new PR. The same PR continues across iterations.
#   - Never pushes the original task's branch from origin/main; always
#     uses the upstream HEAD of the PR branch.
#
# Concurrency note: same as launch-worker.sh — flock fence lands in Task
# 2.3.G; until then, keep ORCH_MAX_PARALLEL=1.
#
# Exit codes:
#   0  iteration done OR iter cap hit (state advanced, handled cleanly)
#   1  hard failure (worker hit 3 retries, push failed, env error)

set -uo pipefail

# ---- Dependency checks ----
command -v jq >/dev/null    || { echo "iterate-pr: jq required" >&2; exit 1; }
command -v gh >/dev/null    || { echo "iterate-pr: gh required" >&2; exit 1; }
command -v gawk >/dev/null  || { echo "iterate-pr: gawk required (BSD awk breaks fence-aware parsing)" >&2; exit 1; }
command -v claude >/dev/null || { echo "iterate-pr: claude CLI required" >&2; exit 1; }

# ---- Args ----
if [ $# -ne 2 ]; then
  echo "usage: $0 <state_file> <task_num>" >&2
  exit 1
fi

RAW_STATE_FILE="$1"
TASK_NUM="$2"

[ -f "$RAW_STATE_FILE" ] || { echo "iterate-pr: state file not found: $RAW_STATE_FILE" >&2; exit 1; }
[[ "$TASK_NUM" =~ ^[0-9]+$ ]] || { echo "iterate-pr: task_num must be numeric, got '$TASK_NUM'" >&2; exit 1; }

REPO=$(git rev-parse --show-toplevel) || { echo "iterate-pr: not inside a git work tree" >&2; exit 1; }
cd "$REPO" || { echo "iterate-pr: cd to repo root failed" >&2; exit 1; }

# shellcheck source=_dispatcher_lib.sh
source "$REPO/.claude/scripts/_dispatcher_lib.sh"

# Absolute path so subsequent `cd "$WT"` doesn't break state reads/writes.
case "$RAW_STATE_FILE" in
  /*) STATE_FILE="$RAW_STATE_FILE" ;;
  *)  STATE_FILE="$REPO/$RAW_STATE_FILE" ;;
esac

NOTIFY=".claude/scripts/notify.sh"
REPO_OWNER_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
[ -n "$REPO_OWNER_REPO" ] || { echo "iterate-pr: could not detect repo via gh" >&2; exit 1; }

# v2 schema check
jq -e --arg t "$TASK_NUM" '.tasks[$t] | type == "object"' "$STATE_FILE" >/dev/null 2>&1 || {
  echo "iterate-pr: task $TASK_NUM missing from state .tasks (state may be v1)" >&2
  exit 1
}

# ---- Read task state ----
TASK_STATUS=$(jq -r --arg t "$TASK_NUM" '.tasks[$t].status // "unknown"' "$STATE_FILE")
PR_NUM=$(jq -r --arg t "$TASK_NUM" '.tasks[$t].pr // empty' "$STATE_FILE")
RETRIES=$(jq -r --arg t "$TASK_NUM" '.tasks[$t].retries // 0' "$STATE_FILE")
PLAN_FILE=$(jq -r '.plan_file' "$STATE_FILE")
TOTAL=$(jq -r '.total_tasks' "$STATE_FILE")
PLAN_BASE=$(basename "$PLAN_FILE" .md)
PLAN_NUM=$(echo "$PLAN_BASE" | grep -oE 'PLAN-[0-9]+' | grep -oE '[0-9]+' || echo "00")

if [ "$TASK_STATUS" != "in_review" ]; then
  echo "iterate-pr: task $TASK_NUM status is '$TASK_STATUS', not 'in_review' — refusing to iterate" >&2
  exit 1
fi
if [ -z "$PR_NUM" ]; then
  echo "iterate-pr: task $TASK_NUM has no .pr set — refusing to iterate" >&2
  exit 1
fi

ITER_CAP="${ORCH_REVIEW_MAX_ITERS:-5}"
[[ "$ITER_CAP" =~ ^[0-9]+$ ]] || { echo "iterate-pr: ORCH_REVIEW_MAX_ITERS must be numeric, got '$ITER_CAP'" >&2; exit 1; }

# Atomic state write helper — delegates to lib (mkdir-based lock makes
# this safe with MAX_PARALLEL > 1).
update_state() {
  local jq_expr="$1"
  if state_write "$STATE_FILE" "$jq_expr" --arg t "$TASK_NUM"; then
    return 0
  fi
  echo "iterate-pr: state_write failed for task $TASK_NUM (jq or lock)" >&2
  return 1
}

# ---- Fetch PR metadata ----
PR_INFO=$(gh pr view "$PR_NUM" --repo "$REPO_OWNER_REPO" \
  --json number,headRefName,baseRefName,headRefOid,body,state 2>/dev/null) || {
  echo "iterate-pr: failed to fetch PR #$PR_NUM" >&2
  exit 1
}

PR_STATE=$(echo "$PR_INFO" | jq -r '.state')
if [ "$PR_STATE" != "OPEN" ]; then
  echo "iterate-pr: PR #$PR_NUM is $PR_STATE — sweep-merges should handle, not iterate-pr" >&2
  exit 1
fi

HEAD_REF=$(echo "$PR_INFO" | jq -r '.headRefName')
HEAD_OID=$(echo "$PR_INFO" | jq -r '.headRefOid')
PR_BODY=$(echo "$PR_INFO" | jq -r '.body // ""')

# ---- Iter cap check ----
PRIOR_ITER=$(echo "$PR_BODY" | grep -oE 'orch:review-iter:[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "0")

if [ "$PRIOR_ITER" -ge "$ITER_CAP" ]; then
  echo "iterate-pr: task $TASK_NUM PR #$PR_NUM hit iter cap ($PRIOR_ITER >= $ITER_CAP); blocking"
  update_state '.tasks[$t].status = "blocked"
    | .tasks[$t].blocked_at = (now | todateiso8601)
    | .tasks[$t].blocked_reason = "review_iter_cap"' || {
    echo "iterate-pr: state update failed during iter-cap block" >&2
    exit 1
  }

  if gh label list --repo "$REPO_OWNER_REPO" --search "orch:review-blocked" 2>/dev/null | grep -q 'orch:review-blocked'; then
    gh pr edit "$PR_NUM" --repo "$REPO_OWNER_REPO" --add-label "orch:review-blocked" >/dev/null 2>&1 \
      || echo "iterate-pr: warning — failed to apply orch:review-blocked label" >&2
  fi

  [ -x "$NOTIFY" ] && bash "$NOTIFY" "plan $PLAN_NUM task $TASK_NUM iter cap hit" \
    "PR #$PR_NUM hit $ITER_CAP review iterations without converging. Investigate manually."
  exit 0
fi

NEW_ITER=$((PRIOR_ITER + 1))
echo "iterate-pr: task=$TASK_NUM/$TOTAL pr=#$PR_NUM iter=$NEW_ITER/$ITER_CAP retries=$RETRIES head=${HEAD_OID:0:8}"

# ---- Fetch reviewer findings (latest orchestrator review only) ----
# Accept both CHANGES_REQUESTED and COMMENTED — review-pr.sh falls back to
# COMMENT when the PR author equals the orchestrator's gh user (GitHub's
# self-review restriction). Filter to reviews authored by the orchestrator
# (body starts with the canonical "**Orchestrator review**" prefix); we
# never iterate on human reviews — humans take it over.
# Iterate-pass.sh has already filtered on the orch:review-blocked label
# before calling us, so the latest matching review is trusted to be a blocker.
REVIEWS_JSON=$(gh api "repos/$REPO_OWNER_REPO/pulls/$PR_NUM/reviews" --paginate 2>/dev/null) || {
  echo "iterate-pr: failed to fetch reviews for PR #$PR_NUM" >&2
  exit 1
}

LATEST_REVIEW=$(echo "$REVIEWS_JSON" \
  | jq '[
      .[]
      | select(.state == "CHANGES_REQUESTED" or .state == "COMMENTED")
      | select((.body // "") | startswith("**Orchestrator review**"))
    ] | sort_by(.submitted_at) | last // null')

if [ "$LATEST_REVIEW" = "null" ] || [ -z "$LATEST_REVIEW" ]; then
  echo "iterate-pr: PR #$PR_NUM has no orchestrator review (CHANGES_REQUESTED or COMMENTED); skipping" >&2
  exit 1
fi

REVIEW_ID=$(echo "$LATEST_REVIEW" | jq -r '.id')
REVIEW_BODY=$(echo "$LATEST_REVIEW" | jq -r '.body // ""')
REVIEW_SHA=$(echo "$LATEST_REVIEW" | jq -r '.commit_id // "unknown"')
# Author of the review we're iterating on. We scope inline comments to this
# same author below so a reply or comment by a third party can never inject
# instructions into the bypassPermissions iterator.
REVIEW_AUTHOR=$(echo "$LATEST_REVIEW" | jq -r '.user.login // ""')

# Inline comments are scoped by BOTH the review id AND the review's author.
# Matching on review id alone is not sufficient: a reply by another user can
# carry the orchestrator's pull_request_review_id, and the body of every
# matched comment is interpolated verbatim into the iterator prompt (which
# runs with bypassPermissions). Requiring author == the orchestrator review's
# author closes that injection path. If the author is somehow empty, fall
# back to id-only scoping rather than including everything.
INLINE_COMMENTS_JSON=$(gh api "repos/$REPO_OWNER_REPO/pulls/$PR_NUM/comments" --paginate 2>/dev/null || echo "[]")
SCOPED_COMMENTS=$(echo "$INLINE_COMMENTS_JSON" \
  | jq --argjson rid "$REVIEW_ID" --arg author "$REVIEW_AUTHOR" \
      '[.[] | select(.pull_request_review_id == $rid and ($author == "" or (.user.login == $author)))]')

INLINE_COUNT=$(echo "$SCOPED_COMMENTS" | jq 'length')
echo "iterate-pr: latest CHANGES_REQUESTED review id=$REVIEW_ID sha=${REVIEW_SHA:0:8} inline_comments=$INLINE_COUNT"

# Pretty-format the inline comments for the prompt.
INLINE_BLOCK=$(echo "$SCOPED_COMMENTS" | jq -r '.[] |
  "- `" + (.path // "?") + ":" + ((.line // .original_line // 0) | tostring) + "` — " +
  (.body | gsub("\n"; "\n  "))')

# ---- Locate plan + extract task spec ----
case "$PLAN_FILE" in
  /*) ABS_PLAN_FILE="$PLAN_FILE" ;;
  *)  ABS_PLAN_FILE="$REPO/$PLAN_FILE" ;;
esac
[ -f "$ABS_PLAN_FILE" ] || {
  echo "iterate-pr: plan file '$ABS_PLAN_FILE' (from state) does not exist" >&2
  exit 1
}

# Fence-aware extract — same pattern as launch-worker.sh / review-pr.sh.
TASK_CONTENT=$(gawk -v task="## Task ${TASK_NUM}:" '
  /^```/ { in_fence = !in_fence; if (found) print; next }
  in_fence { if (found) print; next }
  $0 ~ "^" task { found = 1; print; next }
  found && /^## Task / { exit }
  found && /^## / && !/^## Task / { exit }
  found { print }
' "$ABS_PLAN_FILE")

if [ -z "$TASK_CONTENT" ]; then
  echo "iterate-pr: could not extract '## Task $TASK_NUM:' from $ABS_PLAN_FILE" >&2
  exit 1
fi

# ---- Worktree on the PR's existing branch ----
# CRITICAL: no `-B` flag. We want a checkout of the existing branch with
# its history intact. `-B` would reset the branch and trash the worker's
# prior commit.
WT="../wt-iter-plan${PLAN_NUM}-t${TASK_NUM}"

git worktree remove "$WT" --force 2>/dev/null || true
git fetch origin "$HEAD_REF" --quiet 2>/dev/null || {
  echo "iterate-pr: failed to fetch origin/$HEAD_REF" >&2
  exit 1
}

# Create a local tracking branch from origin/<HEAD_REF> if missing; the
# worktree add then checks it out. The intermediate branch name uses an
# iteration suffix so it can't collide with launch-worker's branch lock.
LOCAL_BRANCH="iter/$HEAD_REF"
git branch -f "$LOCAL_BRANCH" "origin/$HEAD_REF" 2>/dev/null || true
git worktree add "$WT" "$LOCAL_BRANCH" 2>/dev/null || {
  echo "iterate-pr: git worktree add failed for $LOCAL_BRANCH at $WT" >&2
  exit 1
}

# Register before any work begins. Graceful exit paths below unregister;
# signal-induced exits skip so the orchestrator's trap cleans the leak.
register_worktree "$WT"

cd "$WT" || {
  echo "iterate-pr: cd to worktree $WT failed" >&2
  unregister_worktree "$WT"
  exit 1
}

# ---- Build iteration prompt ----
ITER_SYSTEM="$REPO/.claude/prompts/iterator-system.md"
[ -f "$ITER_SYSTEM" ] || {
  echo "iterate-pr: iterator system prompt missing: $ITER_SYSTEM" >&2
  cd "$REPO" || exit 1
  git worktree remove "$WT" --force 2>/dev/null || true
  unregister_worktree "$WT"
  exit 1
}

RUN_OUT="$REPO/.claude/state/iter-plan${PLAN_NUM}-t${TASK_NUM}-i${NEW_ITER}-r${RETRIES}.json"
mkdir -p "$(dirname "$RUN_OUT")"

WORKER_MODEL="${ORCH_WORKER_MODEL:-opus}"
MAX_TURNS="${ORCH_MAX_TURNS:-60}"
WORKER_TIMEOUT="${ORCH_WORKER_TIMEOUT:-600}"
TIMEOUT_CMD=$(find_timeout_cmd)

ITER_PROMPT=$(cat <<EOF
$(cat "$ITER_SYSTEM")

---

## Active plan path (for cross-reference)
$ABS_PLAN_FILE

## Your assignment

You are iterating on PR #$PR_NUM (branch \`$HEAD_REF\`) for plan $PLAN_NUM,
task $TASK_NUM of $TOTAL. This is iteration $NEW_ITER of $ITER_CAP.

Apply the reviewer's blockers below to the working tree (the PR branch is
already checked out), commit, then exit. The orchestrator will push your
commits — do NOT push yourself.

### Original task spec (verbatim from plan)

$TASK_CONTENT

---

### Latest reviewer verdict (against sha ${REVIEW_SHA:0:8})

$REVIEW_BODY

---

### Inline reviewer comments ($INLINE_COUNT)

${INLINE_BLOCK:-(no inline comments — see review body above)}

---

### Reminder

Address ONLY the reviewer's blockers. \`important\` and \`nit\` findings are
optional. Stay strictly within the original task's scope. Drive-by edits go
to a follow-up issue, not into this commit.

Return ONLY the JSON object specified in the system prompt above. No prose,
no markdown fences around it.
EOF
)

# Build invocation as array so the timeout prefix is optional without
# duplicating the claude command. Exit 124 from `timeout` is a worker
# failure and naturally counts toward retries.
RUN_CMD=()
if [ -n "$TIMEOUT_CMD" ]; then
  RUN_CMD=("$TIMEOUT_CMD" "${WORKER_TIMEOUT}s")
  echo "iterate-pr: spawning iterator (model=$WORKER_MODEL, max-turns=$MAX_TURNS, timeout=${WORKER_TIMEOUT}s)..."
else
  echo "iterate-pr: spawning iterator (model=$WORKER_MODEL, max-turns=$MAX_TURNS, timeout=NONE — install coreutils/gtimeout)..."
fi
# bypassPermissions because acceptEdits blocks Bash (git commit, gh issue
# create for follow-ups) and the worker silently fails after writing files
# but before committing. Same lesson as launch-worker.sh.
RUN_CMD+=(claude -p "$ITER_PROMPT"
  --permission-mode bypassPermissions
  --output-format json
  --model "$WORKER_MODEL"
  --max-turns "$MAX_TURNS")

"${RUN_CMD[@]}" > "$RUN_OUT"
WORKER_EXIT=$?
if [ "$WORKER_EXIT" = "124" ] && [ -n "$TIMEOUT_CMD" ]; then
  echo "iterate-pr: iterator exceeded ${WORKER_TIMEOUT}s timeout — counted as failure"
fi

cd "$REPO" || { echo "iterate-pr: cd back to $REPO failed" >&2; exit 1; }

# Capture iterator usage. Same pattern as launch-worker — runs even on
# failed iterations so cost-of-retry is visible to the operator. PR
# comment posted below only if the iter produced parseable output.
USAGE_LINE=$(extract_usage_summary "$RUN_OUT")
if [ -n "$USAGE_LINE" ]; then
  echo "iterate-pr: usage [iterator i$NEW_ITER r$RETRIES] $USAGE_LINE"
  update_task_usage "$STATE_FILE" "$TASK_NUM" "$RUN_OUT" iterator || \
    echo "iterate-pr: warning — failed to persist usage to state" >&2
  gh pr comment "$PR_NUM" --body "**Usage** (iterator, iter $NEW_ITER / retry $RETRIES): \`$USAGE_LINE\`" >/dev/null 2>&1 || \
    echo "iterate-pr: warning — failed to post usage comment to PR #$PR_NUM" >&2
fi

if [ $WORKER_EXIT -ne 0 ]; then
  NEW_RETRIES=$((RETRIES + 1))
  echo "iterate-pr: worker exited $WORKER_EXIT; retry $NEW_RETRIES/3"
  if [ "$NEW_RETRIES" -ge 3 ]; then
    update_state '.tasks[$t].status = "blocked"
      | .tasks[$t].retries = 3
      | .tasks[$t].blocked_at = (now | todateiso8601)
      | .tasks[$t].blocked_reason = "iterate_failed_3x"' || true
    [ -x "$NOTIFY" ] && bash "$NOTIFY" "plan $PLAN_NUM task $TASK_NUM iterate failed 3x" \
      "Iteration worker failed 3 times on PR #$PR_NUM. Investigate $RUN_OUT and worktree $WT"
    # Worktree preserved for inspection; unregister so the orchestrator
    # trap doesn't auto-remove it on tick exit.
    unregister_worktree "$WT"
    exit 1
  else
    update_state ".tasks[\$t].retries = $NEW_RETRIES" || true
    # Worktree preserved for retry inspection; unregister for same reason.
    unregister_worktree "$WT"
    exit 0
  fi
fi

echo "iterate-pr: worker succeeded"

# ---- Push the new commits onto the same PR branch ----
cd "$WT" || { echo "iterate-pr: cd to worktree $WT failed before push" >&2; exit 1; }

# Check whether the worker actually committed anything. If HEAD didn't
# advance past the upstream, push would be a no-op but we still want a
# clean log signal.
LOCAL_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
if [ "$LOCAL_HEAD" = "$HEAD_OID" ]; then
  echo "iterate-pr: worker produced no new commits (HEAD unchanged at ${HEAD_OID:0:8})" >&2
  cd "$REPO" || exit 1
  # Reset retries — the worker ran cleanly, just had nothing to commit.
  # That can happen when the worker decided every finding was out of scope.
  update_state '.tasks[$t].retries = 0' || true
  git worktree remove "$WT" --force 2>/dev/null || true
  unregister_worktree "$WT"
  exit 0
fi

if ! git push origin "HEAD:$HEAD_REF" --quiet 2> /tmp/orch-iter-push.$$.err; then
  PUSH_ERR=$(cat /tmp/orch-iter-push.$$.err 2>/dev/null || echo "")
  rm -f /tmp/orch-iter-push.$$.err
  echo "iterate-pr: git push failed: $PUSH_ERR" >&2
  [ -x "$NOTIFY" ] && bash "$NOTIFY" "iterate push failed" \
    "plan $PLAN_NUM task $TASK_NUM PR #$PR_NUM — $PUSH_ERR. State NOT advanced; next tick will retry."
  cd "$REPO" || true
  # Worktree preserved (operator may want to inspect); unregister so the
  # orchestrator trap doesn't auto-remove it.
  unregister_worktree "$WT"
  exit 1
fi
rm -f /tmp/orch-iter-push.$$.err

cd "$REPO" || { echo "iterate-pr: cd back to $REPO failed after push" >&2; unregister_worktree "$WT"; exit 1; }

# Worker pushed successfully — reset retries. Status stays in_review;
# review-pass will re-review the new HEAD on next tick.
if ! update_state '.tasks[$t].retries = 0'; then
  echo "iterate-pr: warning — state update failed after successful push (manual reconcile may be needed)" >&2
fi

git worktree remove "$WT" --force 2>/dev/null || true
unregister_worktree "$WT"

echo "iterate-pr: done (task $TASK_NUM, PR #$PR_NUM, iter=$NEW_ITER pushed)"
exit 0
