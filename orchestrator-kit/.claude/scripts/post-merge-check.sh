#!/usr/bin/env bash
# Watch CI on main for a merged PR's commit; notify on red (Task 5.2).
#
# Usage: post-merge-check.sh <pr_num> [<owner/repo>]
#
# Designed to be launched in the background by sweep-merges.sh
# immediately after a MERGED state transition. It does NOT auto-revert
# — humans decide whether to roll back. Output goes to
# .claude/state/post-merge.log via the orchestrator's redirected fds.
#
# Polling model:
#   1. Fetch mergeCommit.oid from the PR.
#   2. Wait up to ORCH_POST_MERGE_GRACE for any workflow run to register
#      against that SHA (CI may take a few seconds to enqueue).
#   3. Poll all runs for that SHA on a fixed interval. When every run
#      reaches `completed`, evaluate conclusions.
#   4. Any non-success conclusion -> notify with a `git revert` command.
#
# Knobs:
#   ORCH_POST_MERGE_TIMEOUT   total seconds before giving up   (default 1800 = 30 min)
#   ORCH_POST_MERGE_GRACE     seconds to wait for runs to register (default 60)
#   ORCH_POST_MERGE_POLL      seconds between polls            (default 30)
#
# Exit codes (informational only — caller backgrounded us):
#   0  CI green OR no CI registered within grace period OR timeout reached
#   1  environment/args failure
#   2  CI red (notification was sent)

set -uo pipefail

command -v jq >/dev/null || { echo "post-merge-check: jq required" >&2; exit 1; }
command -v gh >/dev/null || { echo "post-merge-check: gh required" >&2; exit 1; }

if [ $# -lt 1 ]; then
  echo "usage: $0 <pr_num> [<owner/repo>]" >&2
  exit 1
fi

PR_NUM="$1"
REPO="${2:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"

[[ "$PR_NUM" =~ ^[0-9]+$ ]] || { echo "post-merge-check: PR num must be numeric, got '$PR_NUM'" >&2; exit 1; }
[ -n "$REPO" ] || { echo "post-merge-check: no repo and gh autodetect failed" >&2; exit 1; }

TIMEOUT="${ORCH_POST_MERGE_TIMEOUT:-1800}"
GRACE="${ORCH_POST_MERGE_GRACE:-60}"
POLL="${ORCH_POST_MERGE_POLL:-30}"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
NOTIFY="$REPO_ROOT/.claude/scripts/notify.sh"

MERGE_SHA=$(gh pr view "$PR_NUM" --repo "$REPO" --json mergeCommit -q .mergeCommit.oid 2>/dev/null)
if [ -z "$MERGE_SHA" ] || [ "$MERGE_SHA" = "null" ]; then
  echo "post-merge-check: PR #$PR_NUM has no merge commit (not merged?); exiting"
  exit 0
fi
SHORT_SHA="${MERGE_SHA:0:8}"
echo "post-merge-check: watching CI on $SHORT_SHA (PR #$PR_NUM) timeout=${TIMEOUT}s"

# Phase 1: wait for runs to register (CI may be slow to enqueue).
elapsed=0
RUNS_JSON=""
while [ "$elapsed" -lt "$GRACE" ]; do
  RUNS_JSON=$(gh api "repos/$REPO/actions/runs?head_sha=$MERGE_SHA" --jq '.workflow_runs // []' 2>/dev/null || echo "[]")
  COUNT=$(echo "$RUNS_JSON" | jq 'length')
  if [ "${COUNT:-0}" -gt 0 ]; then
    echo "post-merge-check: $COUNT run(s) registered for $SHORT_SHA after ${elapsed}s"
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

COUNT=$(echo "$RUNS_JSON" | jq 'length' 2>/dev/null || echo 0)
if [ "${COUNT:-0}" -eq 0 ]; then
  echo "post-merge-check: no CI runs registered within ${GRACE}s grace; no CI configured? exiting"
  exit 0
fi

# Phase 2: poll until every run reaches `completed` or we time out.
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
  RUNS_JSON=$(gh api "repos/$REPO/actions/runs?head_sha=$MERGE_SHA" --jq '.workflow_runs // []' 2>/dev/null || echo "[]")
  INCOMPLETE=$(echo "$RUNS_JSON" | jq '[.[] | select(.status != "completed")] | length')

  if [ "${INCOMPLETE:-0}" -eq 0 ]; then
    # All done — evaluate conclusions.
    BAD=$(echo "$RUNS_JSON" | jq -r '
      [.[] | select(.conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral")
           | "\(.name) (\(.conclusion))"
      ] | join(", ")
    ')
    if [ -z "$BAD" ]; then
      echo "post-merge-check: all CI runs green on $SHORT_SHA — done"
      exit 0
    fi

    REVERT_CMD="git revert $MERGE_SHA"
    echo "post-merge-check: CI RED on $SHORT_SHA — $BAD"
    if [ -x "$NOTIFY" ]; then
      bash "$NOTIFY" "main CI red after PR #$PR_NUM" \
        "Commit $SHORT_SHA broke main CI: $BAD. Suggested revert: \`$REVERT_CMD\` (review first — orchestrator does not auto-revert)."
    fi
    exit 2
  fi

  sleep "$POLL"
  elapsed=$((elapsed + POLL))
done

echo "post-merge-check: timeout (${TIMEOUT}s) waiting for CI completion on $SHORT_SHA — abandoning watch"
exit 0
