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
#   - repo has allow_auto_merge enabled (gh pr merge --auto needs it)
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

# Repo-level allow_auto_merge must be true. `gh repo edit --enable-auto-merge`
# is known to silently no-op on some gh versions / repo states, so we read
# the resulting setting via the API rather than trusting the enable command.
AM_OUTPUT=$(gh api "repos/$REPO" --jq '.allow_auto_merge' 2>&1)
AM_EXIT=$?

if [ $AM_EXIT -ne 0 ]; then
  echo "FAIL: could not read allow_auto_merge for $REPO" >&2
  echo "$AM_OUTPUT" | sed 's/^/  /' >&2
  exit 1
fi

if [ "$AM_OUTPUT" != "true" ]; then
  echo "FAIL: $REPO has allow_auto_merge=$AM_OUTPUT (must be true)" >&2
  echo "  gh pr merge --auto silently no-ops without this; the orchestrator" >&2
  echo "  loop will stall on every PR until a human merges it." >&2
  echo "  fix:" >&2
  echo "    gh api repos/$REPO -X PATCH -f allow_auto_merge=true \\" >&2
  echo "      --jq '.allow_auto_merge'" >&2
  echo "  (expect 'true' on stdout; re-run this script to confirm)" >&2
  exit 1
fi

echo "OK: $REPO has allow_auto_merge=true"

# ---------------------------------------------------------------------------
# Skill-presence preflight: check that Claude Code plugins required by
# AWS-flagged plans are installed.
#
# Scans .claude/plans/*.md (non-archive) for state files containing aws_env.
# If any active plan has aws_env, requires:
#   - Always: aws-core, aws-agents
#   - Conditionally (plan/task body mentions agentcore/AgentCore):
#     cdk-agentcore, agentcore-deploy-runbook, agentcore-architect
# ---------------------------------------------------------------------------

PLANS_DIR="$(git rev-parse --show-toplevel)/.claude/plans"
MISSING_PLUGINS=()
AWS_FLAGGED=0
NEEDS_AGENTCORE=0

if [ -d "$PLANS_DIR" ]; then
  for plan_md in "$PLANS_DIR"/*.md; do
    [ -e "$plan_md" ] || continue  # no glob match
    # Derive state file path from plan markdown path
    state_file="${plan_md%.md}.state.json"
    [ -f "$state_file" ] || continue
    # Check if this plan has an aws_env block
    has_aws=$(jq '.aws_env // empty' "$state_file" 2>/dev/null)
    [ -n "$has_aws" ] || continue
    AWS_FLAGGED=1
    # Check whether plan prose mentions agentcore (case-insensitive)
    if grep -qi 'agentcore' "$plan_md" 2>/dev/null; then
      NEEDS_AGENTCORE=1
    fi
  done
fi

if [ "$AWS_FLAGGED" -eq 0 ]; then
  echo "skill preflight: no AWS-flagged plans, skipping"
  exit 0
fi

# Verify claude CLI is available before running plugin list
if ! command -v claude >/dev/null 2>&1; then
  echo "FAIL: claude CLI not on PATH — install per https://docs.anthropic.com/en/docs/claude-code/setup" >&2
  exit 1
fi

# Capture plugin list as JSON. Using --json (ASCII, stable schema) avoids
# fragile TTY-decorator parsing — the human-readable output uses U+276F "❯"
# and Unicode status glyphs (✔/✘) that aren't guaranteed across locales,
# CI environments, or future claude CLI versions.
#
# An installed-but-disabled plugin is effectively absent for the kit's
# purposes (workers can't reach its skills), so we filter on .enabled == true.
PLUGIN_LIST=$(claude plugin list --json 2>&1)
PLUGIN_LIST_EXIT=$?
if [ $PLUGIN_LIST_EXIT -ne 0 ]; then
  echo "FAIL: 'claude plugin list --json' failed (exit $PLUGIN_LIST_EXIT)" >&2
  echo "$PLUGIN_LIST" | sed 's/^/  /' >&2
  exit 1
fi

# Extract enabled plugin names, stripping "@<source>" suffix from each .id.
# If jq can't parse (e.g., CLI emitted non-JSON warnings), ENABLED_PLUGINS
# stays empty and every required plugin will be flagged missing — the safer
# default than silently passing.
ENABLED_PLUGINS=$(echo "$PLUGIN_LIST" | jq -r '
  if type == "array" then
    .[] | select(.enabled == true) | .id | split("@")[0]
  else empty end
' 2>/dev/null || true)

# Helper: check if a plugin name is in the enabled-plugins list.
# grep -xF: whole-line literal match, ASCII-only, no regex metacharacter risk.
plugin_installed() {
  local name="$1"
  grep -qxF "$name" <<< "$ENABLED_PLUGINS"
}

# Always-required for AWS-flagged plans
for plugin in aws-core aws-agents; do
  if ! plugin_installed "$plugin"; then
    MISSING_PLUGINS+=("$plugin")
  fi
done

# Conditionally required when plan mentions agentcore
if [ "$NEEDS_AGENTCORE" -eq 1 ]; then
  for plugin in cdk-agentcore agentcore-deploy-runbook agentcore-architect; do
    if ! plugin_installed "$plugin"; then
      MISSING_PLUGINS+=("$plugin")
    fi
  done
fi

if [ ${#MISSING_PLUGINS[@]} -gt 0 ]; then
  for plugin in "${MISSING_PLUGINS[@]}"; do
    echo "missing plugin: $plugin — install: claude plugin install $plugin" >&2
  done
  exit 1
fi

echo "skill preflight: all required plugins present"
exit 0
