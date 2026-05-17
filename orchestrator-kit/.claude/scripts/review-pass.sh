#!/usr/bin/env bash
# Dispatcher Phase 3: review PRs whose HEAD SHA has advanced past the
# last reviewed marker.
#
# Usage: review-pass.sh <state_file> [<owner/repo>]
#
# For each task in state.tasks.* with status == "in_review" and .pr set:
#   1. Fetch the PR's body + headRefOid + state from gh.
#   2. If state != OPEN, skip (sweep-merges handles closed/merged).
#   3. Extract last reviewed SHA from the PR body marker
#      `<!-- orch:review-sha:<hash> -->`. Missing marker = never reviewed.
#   4. If HEAD SHA == last reviewed SHA, skip (already up to date).
#   5. Otherwise, spawn review-pr.sh <pr> <repo> in the background.
#
# Reviewers run in parallel up to ORCH_MAX_PARALLEL_REVIEWS (default =
# ORCH_MAX_PARALLEL, default 1). Cap is enforced with a poll loop
# (portable to macOS bash 3.2; `wait -n` would not be).
#
# Exit codes:
#   0  pass complete (zero or more reviewers spawned; all returned)
#   1  environment/args/state-file failure

set -uo pipefail

command -v jq >/dev/null || { echo "review-pass: jq required" >&2; exit 1; }
command -v gh >/dev/null || { echo "review-pass: gh required" >&2; exit 1; }

if [ $# -lt 1 ]; then
  echo "usage: $0 <state_file> [<owner/repo>]" >&2
  exit 1
fi

STATE_FILE="$1"
REPO="${2:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"

[ -f "$STATE_FILE" ] || { echo "review-pass: state file not found: $STATE_FILE" >&2; exit 1; }
[ -n "$REPO" ] || {
  echo "review-pass: no repo specified and gh auto-detect failed" >&2
  exit 1
}

# v2 schema check
jq -e '.tasks | type == "object"' "$STATE_FILE" >/dev/null 2>&1 || {
  echo "review-pass: state file lacks .tasks object (expected v2 schema)" >&2
  exit 1
}

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
REVIEWER="${ORCH_REVIEW_PR:-$REPO_ROOT/.claude/scripts/review-pr.sh}"
REBASE_PR="${ORCH_REBASE_PR:-$REPO_ROOT/.claude/scripts/rebase-pr.sh}"
MAX_REVIEWS="${ORCH_MAX_PARALLEL_REVIEWS:-${ORCH_MAX_PARALLEL:-1}}"

[ -x "$REVIEWER" ] || {
  echo "review-pass: review-pr.sh not executable at $REVIEWER" >&2
  exit 1
}
[[ "$MAX_REVIEWS" =~ ^[0-9]+$ ]] || {
  echo "review-pass: max_parallel_reviews must be numeric, got '$MAX_REVIEWS'" >&2
  exit 1
}
# rebase-pr.sh is optional — if absent, CONFLICTING PRs are simply left
# alone and the next tick will see them again. Log once if missing.
HAVE_REBASE=0
[ -x "$REBASE_PR" ] && HAVE_REBASE=1

# Build list: task_num pr_num
REVIEW_LIST=$(jq -r '
  .tasks | to_entries[]
  | select(.value.pr != null and .value.status == "in_review")
  | "\(.key) \(.value.pr)"
' "$STATE_FILE")

if [ -z "$REVIEW_LIST" ]; then
  echo "review-pass: no in_review tasks; nothing to review"
  exit 0
fi

LAUNCHED=0
SKIPPED=0
NOT_OPEN=0
REBASED=0
CONFLICT_DEFERRED=0
REVIEWER_PIDS=()

# Poll-based slot cap. Wait until live PIDs count < MAX_REVIEWS.
wait_for_slot() {
  while true; do
    local alive=()
    for p in "${REVIEWER_PIDS[@]+"${REVIEWER_PIDS[@]}"}"; do
      if kill -0 "$p" 2>/dev/null; then
        alive+=("$p")
      fi
    done
    REVIEWER_PIDS=("${alive[@]+"${alive[@]}"}")
    if [ "${#REVIEWER_PIDS[@]}" -lt "$MAX_REVIEWS" ]; then
      return 0
    fi
    sleep 0.5
  done
}

while read -r task_num pr_num; do
  [ -z "$task_num" ] && continue

  # One gh call for body + sha + state + mergeable
  PR_INFO=$(gh pr view "$pr_num" --repo "$REPO" --json body,headRefOid,state,mergeable 2>/dev/null || echo "")
  if [ -z "$PR_INFO" ]; then
    echo "review-pass: failed to fetch PR #$pr_num (task $task_num); skipping" >&2
    continue
  fi

  PR_STATE=$(echo "$PR_INFO" | jq -r '.state // "UNKNOWN"')
  if [ "$PR_STATE" != "OPEN" ]; then
    echo "review-pass: PR #$pr_num task $task_num is $PR_STATE — skipping (sweep-merges owns this)"
    NOT_OPEN=$((NOT_OPEN + 1))
    continue
  fi

  # Task 4.4: if mergeable=CONFLICTING, hand off to rebase-pr.sh and skip
  # review this tick. UNKNOWN (GitHub still computing) is left to next
  # tick. The HEAD SHA marker comparison comes after — a successful
  # rebase advances the SHA, so the *next* tick re-reviews fresh.
  MERGEABLE=$(echo "$PR_INFO" | jq -r '.mergeable // "UNKNOWN"')
  if [ "$MERGEABLE" = "CONFLICTING" ]; then
    if [ "$HAVE_REBASE" -eq 1 ]; then
      echo "review-pass: PR #$pr_num task $task_num CONFLICTING — invoking rebase-pr.sh"
      if bash "$REBASE_PR" "$pr_num" "$REPO"; then
        REBASED=$((REBASED + 1))
      else
        CONFLICT_DEFERRED=$((CONFLICT_DEFERRED + 1))
      fi
    else
      echo "review-pass: PR #$pr_num CONFLICTING but rebase-pr.sh missing — deferring"
      CONFLICT_DEFERRED=$((CONFLICT_DEFERRED + 1))
    fi
    continue
  fi

  HEAD_OID=$(echo "$PR_INFO" | jq -r '.headRefOid')
  PR_BODY=$(echo "$PR_INFO" | jq -r '.body // ""')
  LAST_SHA=$(echo "$PR_BODY" | grep -oE 'orch:review-sha:[a-f0-9]+' | head -1 | cut -d: -f3)

  if [ -n "$LAST_SHA" ] && [ "$HEAD_OID" = "$LAST_SHA" ]; then
    echo "review-pass: PR #$pr_num task $task_num already reviewed at ${LAST_SHA:0:8}"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  wait_for_slot

  LAST_DISPLAY="${LAST_SHA:-never}"
  echo "review-pass: PR #$pr_num task $task_num head=${HEAD_OID:0:8} last=${LAST_DISPLAY:0:8} -> reviewing"
  bash "$REVIEWER" "$pr_num" "$REPO" &
  REVIEWER_PIDS+=("$!")
  LAUNCHED=$((LAUNCHED + 1))
done <<< "$REVIEW_LIST"

# Wait on every spawned reviewer
for p in "${REVIEWER_PIDS[@]+"${REVIEWER_PIDS[@]}"}"; do
  wait "$p" 2>/dev/null || true
done

echo "review-pass: done — launched=$LAUNCHED skipped=$SKIPPED not_open=$NOT_OPEN rebased=$REBASED conflict_deferred=$CONFLICT_DEFERRED"
exit 0
