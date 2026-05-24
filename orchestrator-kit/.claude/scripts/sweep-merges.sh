#!/usr/bin/env bash
# Sweep pending PRs and transition task state.
#
# Usage: sweep-merges.sh <state_file> [<owner/repo>]
#
# For each task in state.tasks.* with .pr set AND status == "in_review":
#   MERGED   -> tasks.N.status = "merged", `gh issue close <issue>`
#   CLOSED   -> tasks.N.status = "blocked", notify, label issue orch:safety-block
#   OPEN     -> no-op (left for review-pass / iterate-pass)
#   other    -> log + skip (e.g., gh fetch failed)
#
# Reads v2 state schema. Single-writer assumption: caller (orchestrator
# tick) holds the global lock; concurrent invocations against the same
# state file are not safe.
#
# State writes use the kit's atomic-write convention:
#   jq '...' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
# If jq fails, the temp file isn't moved and the original is untouched.
#
# Issue closure is best-effort: state transitions take precedence, and
# a stale-open issue after a successful state write is cosmetic noise,
# not a correctness bug.
#
# Exit codes:
#   0  swept (transitions printed; check log for per-task details)
#   1  environment/args/state-file failure

set -uo pipefail

command -v jq >/dev/null || { echo "sweep-merges: jq required" >&2; exit 1; }
command -v gh >/dev/null || { echo "sweep-merges: gh required" >&2; exit 1; }

if [ $# -lt 1 ]; then
  echo "usage: $0 <state_file> [<owner/repo>]" >&2
  exit 1
fi

STATE_FILE="$1"
REPO="${2:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"

[ -f "$STATE_FILE" ] || { echo "sweep-merges: state file not found: $STATE_FILE" >&2; exit 1; }
[ -n "$REPO" ] || {
  echo "sweep-merges: no repo specified and gh auto-detect failed" >&2
  echo "  pass <owner/repo> as 2nd arg or run from a gh-tracked clone" >&2
  exit 1
}

# v2 schema check
jq -e '.tasks | type == "object"' "$STATE_FILE" >/dev/null 2>&1 || {
  echo "sweep-merges: state file lacks .tasks object (expected v2 schema): $STATE_FILE" >&2
  exit 1
}

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
NOTIFY="$REPO_ROOT/.claude/scripts/notify.sh"

# shellcheck source=_dispatcher_lib.sh
source "$REPO_ROOT/.claude/scripts/_dispatcher_lib.sh"

# Build sweep list: task_num pr_num issue_num (issue may be "null")
SWEEP_LIST=$(jq -r '
  .tasks | to_entries[]
  | select(.value.pr != null and .value.status == "in_review")
  | "\(.key) \(.value.pr) \(.value.issue // "null")"
' "$STATE_FILE")

if [ -z "$SWEEP_LIST" ]; then
  echo "sweep-merges: no in_review tasks with .pr set; nothing to sweep"
  exit 0
fi

PLAN_BASE=$(basename "$(jq -r '.plan_file' "$STATE_FILE")" .md)
PLAN_NUM=$(echo "$PLAN_BASE" | grep -oE 'PLAN-[0-9]+' | grep -oE '[0-9]+' || echo "00")

MERGED_COUNT=0
BLOCKED_COUNT=0
OPEN_COUNT=0
ERROR_COUNT=0

# Atomic per-task state update helper — delegates to lib (mkdir-based
# lock makes this safe with concurrent writers).
update_state() {
  local task_num="$1"
  local jq_expr="$2"
  if state_write "$STATE_FILE" "$jq_expr" --arg t "$task_num"; then
    return 0
  fi
  echo "sweep-merges: state_write failed updating task $task_num (jq or lock)" >&2
  return 1
}

while read -r task_num pr_num issue_num; do
  [ -z "$task_num" ] && continue

  PR_STATE=$(gh pr view "$pr_num" --repo "$REPO" --json state -q .state 2>/dev/null || echo "FETCH_FAILED")

  case "$PR_STATE" in
    MERGED)
      echo "task $task_num: PR #$pr_num MERGED -> marking task merged"
      if update_state "$task_num" '.tasks[$t].status = "merged" | .tasks[$t].merged_at = (now | todateiso8601)'; then
        MERGED_COUNT=$((MERGED_COUNT + 1))
        if [ "$issue_num" != "null" ] && [ -n "$issue_num" ]; then
          gh issue close "$issue_num" --repo "$REPO" --reason completed \
            --comment "Auto-closed by orchestrator after PR #$pr_num merged." >/dev/null 2>&1 \
            || echo "sweep-merges: warning — failed to close issue #$issue_num (already closed?)" >&2
        fi
        # Task 5.2: fork post-merge CI watcher. Logs to its own file so
        # the tick's main log doesn't fill with poll output. We disown
        # so the watcher survives the tick exit; it's notification-only.
        PMC="$REPO_ROOT/.claude/scripts/post-merge-check.sh"
        if [ -x "$PMC" ]; then
          PMC_LOG="$REPO_ROOT/.claude/state/post-merge-pr${pr_num}.log"
          nohup bash "$PMC" "$pr_num" "$REPO" "$STATE_FILE" "$task_num" >> "$PMC_LOG" 2>&1 &
          disown 2>/dev/null || true
          echo "sweep-merges: forked post-merge-check for PR #$pr_num (PID $!, log: $PMC_LOG)"
        fi
      else
        ERROR_COUNT=$((ERROR_COUNT + 1))
      fi
      ;;

    CLOSED)
      echo "task $task_num: PR #$pr_num CLOSED unmerged -> marking task blocked"
      if update_state "$task_num" '.tasks[$t].status = "blocked" | .tasks[$t].blocked_at = (now | todateiso8601) | .tasks[$t].blocked_reason = "pr_closed_unmerged"'; then
        BLOCKED_COUNT=$((BLOCKED_COUNT + 1))
        # 5.7b: cascade-block transitive pending dependents so the plan can
        # archive instead of looping on tasks whose dep will never close.
        cascade_block "$STATE_FILE" "$task_num" || true
        if [ "$issue_num" != "null" ] && [ -n "$issue_num" ]; then
          # Label is best-effort — depends on operator having run setup-labels.sh
          gh issue edit "$issue_num" --repo "$REPO" --add-label "orch:safety-block" >/dev/null 2>&1 \
            || echo "sweep-merges: warning — failed to apply orch:safety-block to issue #$issue_num" >&2
        fi
        if [ -x "$NOTIFY" ]; then
          bash "$NOTIFY" "plan $PLAN_NUM task $task_num blocked" \
            "PR #$pr_num closed without merge. Investigate before re-launching."
        fi
      else
        ERROR_COUNT=$((ERROR_COUNT + 1))
      fi
      ;;

    OPEN)
      echo "task $task_num: PR #$pr_num still OPEN -> no-op (left for review/iterate pass)"
      OPEN_COUNT=$((OPEN_COUNT + 1))
      ;;

    FETCH_FAILED)
      echo "sweep-merges: gh pr view failed for PR #$pr_num (task $task_num); skipping" >&2
      ERROR_COUNT=$((ERROR_COUNT + 1))
      ;;

    *)
      echo "sweep-merges: unexpected PR state '$PR_STATE' for PR #$pr_num (task $task_num); skipping" >&2
      ERROR_COUNT=$((ERROR_COUNT + 1))
      ;;
  esac
done <<< "$SWEEP_LIST"

echo "sweep-merges: done — merged=$MERGED_COUNT blocked=$BLOCKED_COUNT open=$OPEN_COUNT errors=$ERROR_COUNT"
exit 0
