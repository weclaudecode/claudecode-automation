#!/usr/bin/env bash
# cdk-diff.sh <pr-number> [<state-file>]
#
# Checks out a PR's head into a temporary worktree, runs `cdk diff` for
# every stack in the CDK app at aws_env.cdk_app_path, and posts the output
# as a collapsed <details> PR comment.
#
# Also prints the full diff text to stdout so the caller (review-pr.sh) can
# capture it and pass it into the reviewer prompt.
#
# Inputs:
#   $1  PR number
#   $2  (optional) absolute path to the active plan state.json.
#       If omitted, the script auto-discovers the newest *.state.json in
#       $REPO_ROOT/.claude/plans/ (same logic as review-pr.sh).
#
# Environment (propagated by launch-worker.sh / review-pr.sh for AWS plans):
#   AWS_PROFILE, AWS_REGION, CDK_DEFAULT_ACCOUNT, CDK_DEFAULT_REGION
#
# Exit codes:
#   0  diff posted (or gracefully skipped — no cdk.json, no aws_env)
#   1  hard error: bad args, gh API failure, cdk invocation failed fatally
#
# Safety: never runs `cdk deploy`. Only `cdk list` and `cdk diff`.

set -uo pipefail

# ---- Dependency checks ----
command -v jq  >/dev/null || { echo "cdk-diff: jq required" >&2; exit 1; }
command -v gh  >/dev/null || { echo "cdk-diff: gh required" >&2; exit 1; }
command -v git >/dev/null || { echo "cdk-diff: git required" >&2; exit 1; }

# ---- Args ----
if [ $# -lt 1 ]; then
  echo "usage: $0 <pr-number> [<state-file>]" >&2
  exit 1
fi

PR_NUM="$1"
EXPLICIT_STATE="${2:-}"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "cdk-diff: must run inside a git working tree" >&2
  exit 1
}

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
[ -n "$REPO" ] || {
  echo "cdk-diff: could not determine repo slug from gh" >&2
  exit 1
}

# ---- Locate active state file ----
if [ -n "$EXPLICIT_STATE" ]; then
  STATE_FILE="$EXPLICIT_STATE"
else
  STATE_FILE=$(ls -t "$REPO_ROOT"/.claude/plans/*.state.json 2>/dev/null | head -1)
fi

[ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ] || {
  echo "cdk-diff: no state file found — skipping CDK diff" >&2
  exit 0
}

# ---- Check for aws_env block ----
AWS_ENV_BLOCK=$(jq -r '.aws_env // empty' "$STATE_FILE")
if [ -z "$AWS_ENV_BLOCK" ]; then
  echo "cdk-diff: state file has no aws_env block — skipping CDK diff" >&2
  exit 0
fi

CDK_APP_PATH=$(jq -r '.aws_env.cdk_app_path // empty' "$STATE_FILE")
if [ -z "$CDK_APP_PATH" ]; then
  echo "cdk-diff: aws_env.cdk_app_path not set in state file — skipping CDK diff" >&2
  exit 0
fi

# ---- Check cdk command is available ----
command -v cdk >/dev/null || {
  echo "cdk-diff: cdk CLI not found in PATH — skipping CDK diff" >&2
  exit 0
}

# ---- Fetch PR head ref info ----
PR_JSON=$(gh pr view "$PR_NUM" --repo "$REPO" \
  --json headRefName,headRefOid,headRepository,headRepositoryOwner 2>/dev/null) || {
  echo "cdk-diff: failed to fetch PR #$PR_NUM metadata" >&2
  exit 1
}

HEAD_SHA=$(echo "$PR_JSON" | jq -r '.headRefOid')
HEAD_REF=$(echo "$PR_JSON" | jq -r '.headRefName')

[ -n "$HEAD_SHA" ] && [ -n "$HEAD_REF" ] || {
  echo "cdk-diff: could not parse headRefOid or headRefName from PR JSON" >&2
  exit 1
}

# ---- Create temp worktree ----
# Namespaced by PR + SHA prefix so concurrent diff runs on different PRs
# don't collide. Placed one level above REPO_ROOT so it's outside the main
# checkout and invisible to other workers scanning the worktree.
PARENT_DIR=$(dirname "$REPO_ROOT")
WT_DIR="$PARENT_DIR/cdk-diff-wt-pr${PR_NUM}-${HEAD_SHA:0:8}"

# Cleanup trap — runs on every exit path including signals.
cleanup_worktree() {
  if [ -d "$WT_DIR" ]; then
    git worktree remove --force "$WT_DIR" 2>/dev/null || true
  fi
  rm -f "${BODY_TMP:-}" "${STACK_TMP:-}"
}
trap cleanup_worktree EXIT

# Fetch the PR head ref so git worktree add can check it out by SHA.
git fetch origin "$HEAD_REF" 2>/dev/null || {
  echo "cdk-diff: failed to fetch origin/$HEAD_REF" >&2
  exit 1
}

if ! git worktree add "$WT_DIR" "$HEAD_SHA" 2>/dev/null; then
  echo "cdk-diff: git worktree add failed for $HEAD_SHA" >&2
  exit 1
fi

# ---- Resolve CDK app directory inside the worktree ----
# cdk_app_path may be "." (repo root) or a relative subdirectory.
if [ "$CDK_APP_PATH" = "." ] || [ -z "$CDK_APP_PATH" ]; then
  CDK_DIR="$WT_DIR"
else
  CDK_DIR="$WT_DIR/$CDK_APP_PATH"
fi

if [ ! -d "$CDK_DIR" ]; then
  echo "cdk-diff: cdk_app_path directory '$CDK_DIR' does not exist in worktree — skipping CDK diff" >&2
  exit 0
fi

if [ ! -f "$CDK_DIR/cdk.json" ]; then
  echo "cdk-diff: no cdk.json at $CDK_DIR — skipping diff artifact (not a CDK project)" >&2
  exit 0
fi

# ---- Enumerate stacks ----
STACKS=$(cd "$CDK_DIR" && cdk list 2>/dev/null) || {
  echo "cdk-diff: 'cdk list' failed in $CDK_DIR — skipping CDK diff" >&2
  exit 0
}

if [ -z "$STACKS" ]; then
  echo "cdk-diff: 'cdk list' returned no stacks — skipping CDK diff" >&2
  exit 0
fi

# ---- Run cdk diff per stack, build comment body ----
BODY_TMP=$(mktemp)
STACK_TMP=$(mktemp)

# Marker so future ticks can detect and update the comment.
cat > "$BODY_TMP" <<MARKER
<!-- cdk-diff-orchestrator -->
## CDK diff for #${PR_NUM} (HEAD \`${HEAD_SHA:0:12}\`)

MARKER

# Accumulate all diff text for stdout (passed to reviewer prompt).
ALL_DIFF_TEXT=""

while IFS= read -r STACK; do
  [ -z "$STACK" ] && continue
  echo "cdk-diff: running diff for stack: $STACK" >&2

  # cdk diff exits non-zero when there are changes (exit 1) or on error
  # (exit >=2). We capture both stdout and stderr; the output is the artifact
  # regardless of the exit code.
  DIFF_OUTPUT=$(cd "$CDK_DIR" && cdk diff "$STACK" 2>&1) || true

  # Append to stdout accumulator (reviewer context).
  ALL_DIFF_TEXT="${ALL_DIFF_TEXT}### Stack: ${STACK}
${DIFF_OUTPUT}

"

  # Write collapsed details block for the PR comment.
  cat >> "$BODY_TMP" <<DETAIL
<details>
<summary>${STACK}</summary>

\`\`\`
${DIFF_OUTPUT}
\`\`\`

</details>

DETAIL
done <<< "$STACKS"

# ---- Check for an existing cdk-diff comment (idempotent re-post) ----
# We look for the <!-- cdk-diff-orchestrator --> marker in existing comments.
EXISTING_COMMENT_ID=""
EXISTING_COMMENT_ID=$(gh api \
  "repos/$REPO/issues/$PR_NUM/comments" \
  --jq '[.[] | select(.body | contains("<!-- cdk-diff-orchestrator -->"))] | first | .id // empty' \
  2>/dev/null || true)

# ---- Post or update the comment ----
if [ -n "$EXISTING_COMMENT_ID" ]; then
  echo "cdk-diff: updating existing diff comment (id=$EXISTING_COMMENT_ID) on PR #$PR_NUM" >&2
  gh api "repos/$REPO/issues/comments/$EXISTING_COMMENT_ID" \
    -X PATCH \
    --field body="$(cat "$BODY_TMP")" \
    >/dev/null 2>&1 || {
    echo "cdk-diff: warning — failed to update comment $EXISTING_COMMENT_ID; posting new one" >&2
    gh pr comment "$PR_NUM" --repo "$REPO" --body-file "$BODY_TMP" >/dev/null 2>&1 || {
      echo "cdk-diff: warning — failed to post fallback diff comment" >&2
    }
  }
else
  echo "cdk-diff: posting new CDK diff comment on PR #$PR_NUM" >&2
  gh pr comment "$PR_NUM" --repo "$REPO" --body-file "$BODY_TMP" >/dev/null 2>&1 || {
    echo "cdk-diff: warning — failed to post diff comment on PR #$PR_NUM" >&2
    # Non-fatal: diff text still emitted to stdout for the reviewer.
  }
fi

# ---- Emit diff text to stdout for the caller (review-pr.sh) ----
printf '%s\n' "$ALL_DIFF_TEXT"

echo "cdk-diff: done for PR #$PR_NUM" >&2
exit 0
