#!/usr/bin/env bash
# Retry `gh pr merge --auto` for PRs stuck behind a recoverable failure.
#
# Usage: retry-auto-merge.sh <state_file> <owner/repo>
#
# launch-worker.sh labels a PR `orch:needs-robbie` when `gh pr merge --auto`
# fails at PR-creation time (e.g. repo had allow_auto_merge silently off,
# a transient gh API blip, branch protection misconfig). Without recovery,
# the operator must manually re-enable auto-merge for every stuck PR.
#
# This phase script walks tasks in_review whose PRs are labelled
# orch:needs-robbie and re-runs `gh pr merge --auto --squash --delete-branch`.
# Skips PRs that are human-only by design:
#   - tasks where auto_merge_overrides[N] == false (intentional sensitive)
#   - PRs also labelled orch:safety-block (reviewer-flagged sensitive)
#
# On retry success, strips orch:needs-robbie. On retry failure, leaves
# the label and does NOT re-notify (the original failure already alerted).
#
# No state.json mutations — this script only edits PR labels via gh.
#
# Exit codes:
#   0  best-effort done (always; matches refresh-deps / sweep-merges)
#   1  environment/args/state-file failure

set -uo pipefail

command -v jq >/dev/null || { echo "retry-auto-merge: jq required" >&2; exit 1; }
command -v gh >/dev/null || { echo "retry-auto-merge: gh required" >&2; exit 1; }

if [ $# -lt 2 ]; then
  echo "usage: $0 <state_file> <owner/repo>" >&2
  exit 1
fi

STATE_FILE="$1"
REPO="$2"

[ -f "$STATE_FILE" ] || { echo "retry-auto-merge: state file not found: $STATE_FILE" >&2; exit 1; }
[ -n "$REPO" ] || { echo "retry-auto-merge: empty repo argument" >&2; exit 1; }

# v2 schema check
jq -e '.tasks | type == "object"' "$STATE_FILE" >/dev/null 2>&1 || {
  echo "retry-auto-merge: state file lacks .tasks object (expected v2 schema): $STATE_FILE" >&2
  exit 1
}

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

# shellcheck source=_dispatcher_lib.sh
source "$REPO_ROOT/.claude/scripts/_dispatcher_lib.sh"

# Build retry list: task_num pr_num
# Filter to in_review tasks with a PR set. The auto_merge_overrides and
# label checks happen per-task below so the skip reasons are loggable.
RETRY_LIST=$(jq -r '
  .tasks | to_entries[]
  | select(.value.pr != null and .value.status == "in_review")
  | "\(.key) \(.value.pr)"
' "$STATE_FILE")

if [ -z "$RETRY_LIST" ]; then
  echo "retry-auto-merge: no in_review tasks with .pr set; nothing to retry"
  echo "retry-auto-merge: done — retried=0 succeeded=0 skipped=0"
  exit 0
fi

RETRIED_COUNT=0
SUCCEEDED_COUNT=0
SKIPPED_COUNT=0

while read -r task_num pr_num; do
  [ -z "$task_num" ] && continue

  # Skip sensitive tasks BEFORE any gh API call to conserve quota.
  # auto_merge_overrides[N] == false means the operator declared this
  # task human-only at ingest time; retrying --auto would defy intent.
  OVERRIDE=$(jq -r --arg t "$task_num" '.auto_merge_overrides[$t] // "unset"' "$STATE_FILE")
  if [ "$OVERRIDE" = "false" ]; then
    echo "task $task_num: PR #$pr_num skipped (auto_merge_overrides[$task_num] == false)"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  # Fetch PR labels once; suppress stderr so a transient gh failure on
  # this PR doesn't pollute the tick log (the next tick will retry).
  LABELS=$(gh pr view "$pr_num" --repo "$REPO" --json labels --jq '[.labels[].name] | .[]' 2>/dev/null || echo "")

  # Reviewer-flagged sensitive — human merges only. Check BEFORE the
  # needs-robbie check so a PR labelled with both correctly skips.
  if echo "$LABELS" | grep -qFx "orch:safety-block"; then
    echo "task $task_num: PR #$pr_num skipped (orch:safety-block — reviewer-flagged)"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  if ! echo "$LABELS" | grep -qFx "orch:needs-robbie"; then
    # No auto-merge failure recorded for this PR — nothing to retry.
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  # Eligible: retry auto-merge. Capture stderr so a single PR's failure
  # doesn't abort the loop or noisily fail the tick.
  RETRIED_COUNT=$((RETRIED_COUNT + 1))
  MERGE_ERR=$(gh pr merge "$pr_num" --repo "$REPO" --auto --squash --delete-branch 2>&1 >/dev/null) \
    && MERGE_OK=1 || MERGE_OK=0

  if [ "$MERGE_OK" = "1" ]; then
    gh pr edit "$pr_num" --repo "$REPO" --remove-label "orch:needs-robbie" >/dev/null 2>&1 \
      || echo "retry-auto-merge: warning — failed to strip orch:needs-robbie from PR #$pr_num" >&2
    echo "retry-auto-merge: PR #$pr_num auto-merge re-enabled"
    SUCCEEDED_COUNT=$((SUCCEEDED_COUNT + 1))
  else
    # Leave the label so operator visibility is preserved; do NOT
    # re-notify (launch-worker already alerted on the original failure).
    echo "retry-auto-merge: PR #$pr_num retry failed — leaving labelled (${MERGE_ERR:-no error captured})"
  fi
done <<< "$RETRY_LIST"

echo "retry-auto-merge: done — retried=$RETRIED_COUNT succeeded=$SUCCEEDED_COUNT skipped=$SKIPPED_COUNT"
exit 0
