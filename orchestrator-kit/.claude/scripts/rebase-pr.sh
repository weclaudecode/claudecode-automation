#!/usr/bin/env bash
# Attempt to rebase a CONFLICTING PR onto origin/main.
#
# Usage: rebase-pr.sh <pr_num> [<owner/repo>]
#
# Per SDLC-EVOLUTION-PLAN Task 4.4. Called from review-pass.sh whenever a
# PR's mergeable status is CONFLICTING. The original worker's worktree
# has already been removed (launch-worker.sh cleans up after `gh pr
# create`), so this script creates a fresh worktree for the rebase and
# tears it down at the end.
#
# Flow:
#   1. Fetch PR info; bail unless mergeable == CONFLICTING.
#   2. If PR is already orch:safety-block, exit 0 — a human is on it.
#   3. Refuse to rebase non-orchestrator branches (anything that doesn't
#      match claude/plan-NN-task-M). Branch-naming check is the only
#      safety net against rebasing user PRs.
#   4. Create a fresh worktree at the PR branch.
#   5. git fetch origin; git rebase origin/main.
#      - Clean: git push --force-with-lease, cleanup, exit 0. The next
#        review-pass picks up the new HEAD SHA and re-reviews.
#      - Conflict: git rebase --abort, cleanup worktree, label PR
#        orch:safety-block, notify, exit 2.
#
# --force-with-lease (not --force) so the push aborts if someone else
# pushed to the branch in between. PR branches are orchestrator-only by
# convention but lease is cheap insurance.
#
# Exit codes:
#   0  no-op (not conflicting OR already safety-blocked) OR rebase + push succeeded
#   1  environment failure (gh fetch, worktree add, push)
#   2  rebase conflict; PR labeled orch:safety-block, human required

set -uo pipefail

command -v jq >/dev/null || { echo "rebase-pr: jq required" >&2; exit 1; }
command -v gh >/dev/null || { echo "rebase-pr: gh required" >&2; exit 1; }
command -v git >/dev/null || { echo "rebase-pr: git required" >&2; exit 1; }

if [ $# -lt 1 ]; then
  echo "usage: $0 <pr_num> [<owner/repo>]" >&2
  exit 1
fi

PR_NUM="$1"
REPO="${2:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"

[[ "$PR_NUM" =~ ^[0-9]+$ ]] || { echo "rebase-pr: PR num must be numeric, got '$PR_NUM'" >&2; exit 1; }
[ -n "$REPO" ] || { echo "rebase-pr: no repo and gh autodetect failed" >&2; exit 1; }

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "rebase-pr: not inside a git work tree" >&2
  exit 1
}
cd "$REPO_ROOT" || exit 1

NOTIFY="$REPO_ROOT/.claude/scripts/notify.sh"

PR_INFO=$(gh pr view "$PR_NUM" --repo "$REPO" --json mergeable,mergeStateStatus,headRefName,labels 2>/dev/null) || {
  echo "rebase-pr: failed to fetch PR #$PR_NUM" >&2
  exit 1
}

MERGEABLE=$(echo "$PR_INFO" | jq -r '.mergeable // "UNKNOWN"')
MERGE_STATE=$(echo "$PR_INFO" | jq -r '.mergeStateStatus // "UNKNOWN"')
BRANCH=$(echo "$PR_INFO" | jq -r '.headRefName')
HAS_SAFETY_LABEL=$(echo "$PR_INFO" | jq -r '[.labels[]?.name] | contains(["orch:safety-block"])')

# Two reasons to rebase:
#   mergeable=CONFLICTING — actual merge conflict; rebase may abort.
#   mergeStateStatus=BEHIND — no conflict, but strict status checks require
#     the branch to be up-to-date with main before auto-merge fires.
#     Sibling PR merging into main while ours was in flight is the common
#     trigger; without this branch the orchestrator deadlocks on BEHIND.
TRIGGER=""
[ "$MERGEABLE" = "CONFLICTING" ] && TRIGGER="conflict"
[ "$MERGE_STATE" = "BEHIND" ] && TRIGGER="${TRIGGER:+$TRIGGER+}stale"

if [ -z "$TRIGGER" ]; then
  echo "rebase-pr: PR #$PR_NUM mergeable=$MERGEABLE mergeStateStatus=$MERGE_STATE — no rebase needed"
  exit 0
fi

echo "rebase-pr: PR #$PR_NUM trigger=$TRIGGER (mergeable=$MERGEABLE mergeStateStatus=$MERGE_STATE)"

if [ "$HAS_SAFETY_LABEL" = "true" ]; then
  echo "rebase-pr: PR #$PR_NUM already orch:safety-block — skipping (human's on it)"
  exit 0
fi

# Refuse to touch non-orchestrator branches. The only safety net against
# accidentally rebasing a hand-authored PR is the branch-name pattern.
if ! [[ "$BRANCH" =~ ^claude/plan-[0-9]+-task-[0-9]+ ]]; then
  echo "rebase-pr: PR #$PR_NUM branch '$BRANCH' doesn't match orch naming; refusing to rebase" >&2
  exit 1
fi

WT="../wt-rebase-pr${PR_NUM}"
git worktree remove "$WT" --force 2>/dev/null || true

if ! git fetch origin --quiet 2>/dev/null; then
  echo "rebase-pr: git fetch origin failed for PR #$PR_NUM" >&2
  exit 1
fi

# Branch may not exist locally (the worker's worktree was torn down after
# push). Try local first; fall back to origin/<branch>.
if ! git worktree add "$WT" "$BRANCH" 2>/dev/null; then
  if ! git worktree add "$WT" "origin/$BRANCH" 2>/dev/null; then
    echo "rebase-pr: worktree add failed for $BRANCH (PR #$PR_NUM)" >&2
    exit 1
  fi
fi

REBASE_OK=0
( cd "$WT" && git rebase origin/main ) && REBASE_OK=1

if [ "$REBASE_OK" -eq 1 ]; then
  echo "rebase-pr: PR #$PR_NUM rebased cleanly; force-pushing"
  if ( cd "$WT" && git push --force-with-lease origin "$BRANCH" --quiet ); then
    git worktree remove "$WT" --force 2>/dev/null || true
    echo "rebase-pr: PR #$PR_NUM updated; next review-pass will see fresh HEAD"
    exit 0
  fi
  echo "rebase-pr: push failed after clean rebase on PR #$PR_NUM" >&2
  git worktree remove "$WT" --force 2>/dev/null || true
  exit 1
fi

# Rebase conflicted. Abort, clean up, escalate.
echo "rebase-pr: PR #$PR_NUM rebase conflict — aborting and labeling safety-block"
( cd "$WT" && git rebase --abort 2>/dev/null ) || true
git worktree remove "$WT" --force 2>/dev/null || true

gh pr edit "$PR_NUM" --repo "$REPO" --add-label "orch:safety-block" >/dev/null 2>&1 \
  || echo "rebase-pr: warning — failed to apply orch:safety-block to PR #$PR_NUM" >&2

if [ -x "$NOTIFY" ]; then
  bash "$NOTIFY" "PR #$PR_NUM rebase conflict" \
    "PR cannot be cleanly rebased onto main. Labeled orch:safety-block; human required."
fi

exit 2
