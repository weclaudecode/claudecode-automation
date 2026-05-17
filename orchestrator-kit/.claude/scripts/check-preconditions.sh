#!/usr/bin/env bash
# Verify that a target repo's main branch has the protections the
# orchestrator's auto-merge flow depends on.
#
# Usage: check-preconditions.sh [<owner>/<repo>]
#   Default: current repo per `gh repo view`.
#
# Exits 0 if required preconditions hold; 1 otherwise. Warnings
# (non-blocking) are printed to stderr and do not affect exit code.
#
# Required (exit 1 if missing):
#   - main has branch protection
#   - branch protection requires at least one status check context
#
# Warning (non-blocking):
#   - no required PR reviews: auto-merge will merge unreviewed PRs;
#     orchestrator's own reviewer agent becomes the sole gate

set -uo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}"

if [ -z "$REPO" ]; then
  echo "FAIL: no repo specified and 'gh repo view' returned nothing" >&2
  echo "  run from inside a gh-tracked repo or pass <owner>/<repo>" >&2
  exit 1
fi

echo "Checking branch protection for $REPO main..."

# Capture body + exit code separately. gh api writes JSON body to stdout
# on both success and HTTP error responses (4xx), so an empty body alone
# isn't a reliable signal — we need the exit code too.
PROT_OUTPUT=$(gh api "repos/$REPO/branches/main/protection" 2>&1)
PROT_EXIT=$?

if [ $PROT_EXIT -ne 0 ]; then
  if echo "$PROT_OUTPUT" | grep -q "Upgrade to GitHub Pro"; then
    echo "FAIL: $REPO is a private repo on GitHub Free" >&2
    echo "  branch protection requires GitHub Pro or making the repo public" >&2
    echo "  see: https://docs.github.com/billing/managing-billing-for-your-products" >&2
    exit 1
  fi
  if echo "$PROT_OUTPUT" | grep -qE "Branch not protected|Not Found"; then
    echo "FAIL: $REPO main has no branch protection configured" >&2
    echo "  enable at https://github.com/$REPO/settings/branches" >&2
    exit 1
  fi
  echo "FAIL: unexpected error checking branch protection for $REPO main" >&2
  echo "$PROT_OUTPUT" | sed 's/^/  /' >&2
  exit 1
fi

PROT="$PROT_OUTPUT"

CHECKS=$(echo "$PROT" | jq -r '.required_status_checks.contexts // [] | length')
if [ "$CHECKS" -eq 0 ]; then
  echo "FAIL: no required status checks on main" >&2
  echo "  auto-merge will pass through with no green-check gate" >&2
  exit 1
fi

REVIEWS=$(echo "$PROT" | jq -r '.required_pull_request_reviews // null')
if [ "$REVIEWS" = "null" ]; then
  echo "WARN: no required PR reviews configured" >&2
  echo "  orchestrator's reviewer agent will be the only review on auto-merged PRs" >&2
fi

CHECK_NAMES=$(echo "$PROT" | jq -r '.required_status_checks.contexts | join(", ")')
echo "OK: $REPO main has $CHECKS required check(s): $CHECK_NAMES"
exit 0
