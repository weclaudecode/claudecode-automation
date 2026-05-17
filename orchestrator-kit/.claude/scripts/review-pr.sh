#!/usr/bin/env bash
# Post-push code reviewer for an orchestrator PR.
#
# Usage: review-pr.sh <pr-number> [<owner/repo>]
#
# Spawns a fresh `claude -p` reviewer against the PR's diff + task spec
# with a hardcoded deny-list that strips every mutation tool. Parses the
# reviewer's JSON verdict, posts an inline GitHub review (approve or
# request-changes), and records the iteration count + reviewed sha as
# hidden HTML comments in the PR body so the dispatcher can decide
# whether to re-review on the next tick.
#
# Inputs the reviewer receives:
#   1. The reviewer system prompt (orchestrator-kit/.claude/prompts/reviewer-system.md)
#   2. The verbatim "## Task N:" section from the plan markdown
#   3. The PR diff (gh pr diff)
#
# Reviewer tool surface:
#   Deny:  Edit, Write, NotebookEdit, Bash(git push:*), Bash(gh pr merge:*),
#          Bash(gh pr close:*), Bash(gh pr edit:*), Bash(rm:*)
#   Allow: everything else — Read/Grep/Glob and arbitrary Bash so the
#          reviewer can run `git log`, `gh api`, test discovery, etc.
#
# Posting rules:
#   any "safety_block" finding  -> request-changes + label orch:safety-block
#   any "blocker" finding       -> request-changes
#   else                        -> approve
#   findings with file+line     -> posted as inline review comments
#   findings without            -> rolled into the review body
#
# Iteration tracking (read by dispatcher Task 2.3):
#   <!-- orch:review-iter:N -->
#   <!-- orch:review-iter-sha:<headOid> -->
#
# Exit codes:
#   0  review posted (approve OR request-changes)
#   1  environment / args / lookup failure
#   2  reviewer ran but produced unparseable output (no review posted)

set -uo pipefail

# ---- Dependency checks ----
command -v jq >/dev/null    || { echo "review-pr: jq required" >&2; exit 1; }
command -v gh >/dev/null    || { echo "review-pr: gh required" >&2; exit 1; }
command -v gawk >/dev/null  || { echo "review-pr: gawk required (BSD awk breaks fence-aware parsing)" >&2; exit 1; }
command -v claude >/dev/null || { echo "review-pr: claude CLI required" >&2; exit 1; }

# ---- Args ----
if [ $# -lt 1 ]; then
  echo "usage: $0 <pr-number> [<owner/repo>]" >&2
  exit 1
fi

PR_NUM="$1"
REPO="${2:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"

[ -n "$REPO" ] || {
  echo "review-pr: no repo specified and gh auto-detect failed" >&2
  echo "  pass <owner/repo> as 2nd arg or run from a gh-tracked clone" >&2
  exit 1
}

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "review-pr: must run inside a git working tree (need access to plan files)" >&2
  exit 1
}

# ---- Fetch PR metadata ----
PR_JSON=$(gh pr view "$PR_NUM" --repo "$REPO" \
  --json number,headRefName,baseRefName,headRefOid,body,state 2>/dev/null) || {
  echo "review-pr: failed to fetch PR #$PR_NUM from $REPO" >&2
  exit 1
}

PR_STATE=$(echo "$PR_JSON" | jq -r '.state')
[ "$PR_STATE" = "OPEN" ] || {
  echo "review-pr: PR #$PR_NUM is $PR_STATE, not OPEN — refusing to review" >&2
  exit 1
}

HEAD_REF=$(echo "$PR_JSON" | jq -r '.headRefName')
HEAD_OID=$(echo "$PR_JSON" | jq -r '.headRefOid')
PR_BODY=$(echo "$PR_JSON" | jq -r '.body // ""')

# Orchestrator branches look like: claude/plan-NN-task-M
if ! echo "$HEAD_REF" | grep -qE '^claude/plan-[0-9]+-task-[0-9]+$'; then
  echo "review-pr: PR #$PR_NUM head '$HEAD_REF' is not an orchestrator branch — skipping" >&2
  exit 1
fi

PLAN_NUM=$(echo "$HEAD_REF" | sed -E 's|.*plan-([0-9]+)-task-[0-9]+$|\1|')
TASK_NUM=$(echo "$HEAD_REF" | sed -E 's|.*plan-[0-9]+-task-([0-9]+)$|\1|')

# ---- Locate plan + state for this task ----
STATE_FILE=$(ls -t "$REPO_ROOT"/.claude/plans/PLAN-"$PLAN_NUM"-*.state.json 2>/dev/null | head -1)
[ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ] || {
  echo "review-pr: no state file matching PLAN-$PLAN_NUM-*.state.json in $REPO_ROOT/.claude/plans/" >&2
  exit 1
}

PLAN_FILE=$(jq -r '.plan_file' "$STATE_FILE")
# plan_file in state.json may be relative to repo root; resolve.
case "$PLAN_FILE" in
  /*) ;;
  *)  PLAN_FILE="$REPO_ROOT/$PLAN_FILE" ;;
esac
[ -f "$PLAN_FILE" ] || {
  echo "review-pr: plan file '$PLAN_FILE' (from state) does not exist" >&2
  exit 1
}

# Fence-aware extract of "## Task N:" section, same pattern as create-issues.sh.
extract_task_body() {
  local task_num="$1"
  gawk -v task="## Task ${task_num}:" '
    /^```/ { in_fence = !in_fence; if (found) print; next }
    in_fence { if (found) print; next }
    $0 ~ "^" task { found = 1; print; next }
    found && /^## Task / { exit }
    found && /^## / && !/^## Task / { exit }
    found { print }
  ' "$PLAN_FILE"
}

TASK_SPEC=$(extract_task_body "$TASK_NUM")
[ -n "$TASK_SPEC" ] || {
  echo "review-pr: could not extract '## Task $TASK_NUM:' from $PLAN_FILE" >&2
  exit 1
}

# ---- Fetch PR diff ----
PR_DIFF=$(gh pr diff "$PR_NUM" --repo "$REPO" 2>/dev/null) || {
  echo "review-pr: failed to fetch diff for PR #$PR_NUM" >&2
  exit 1
}

if [ -z "$PR_DIFF" ]; then
  echo "review-pr: PR #$PR_NUM has an empty diff — refusing to review" >&2
  exit 1
fi

# ---- Read prior iteration count from PR body ----
PRIOR_ITER=$(echo "$PR_BODY" | grep -oE 'orch:review-iter:[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "0")
NEW_ITER=$((PRIOR_ITER + 1))

# ---- Build reviewer prompt ----
REVIEWER_SYSTEM="$REPO_ROOT/.claude/prompts/reviewer-system.md"
[ -f "$REVIEWER_SYSTEM" ] || {
  echo "review-pr: reviewer system prompt missing: $REVIEWER_SYSTEM" >&2
  exit 1
}

REVIEW_PROMPT=$(cat <<EOF
$(cat "$REVIEWER_SYSTEM")

---

## Task spec (verbatim from plan)

$TASK_SPEC

---

## PR diff (vs base branch)

\`\`\`diff
$PR_DIFF
\`\`\`

---

## Reminder

Return ONLY the JSON object specified above. No prose, no markdown fences
around it. Iteration $NEW_ITER of this PR.
EOF
)

# ---- Spawn reviewer ----
REVIEWER_MODEL="${ORCH_REVIEWER_MODEL:-sonnet}"
REVIEWER_MAX_TURNS="${ORCH_REVIEWER_MAX_TURNS:-20}"

# Deny-list locks the reviewer to read-only. Bash(...) globs match the
# command form; the reviewer can still run `git log`, `gh api`, etc.
DISALLOWED='Edit,Write,NotebookEdit,Bash(git push:*),Bash(gh pr merge:*),Bash(gh pr close:*),Bash(gh pr edit:*),Bash(gh pr review:*),Bash(rm:*)'

echo "review-pr: spawning reviewer (model=$REVIEWER_MODEL, iter=$NEW_ITER, sha=${HEAD_OID:0:8})..."

RUN_OUT=$(mktemp)
trap 'rm -f "$RUN_OUT"' EXIT

# SKIP_REVIEW=1 prevents this child claude -p from tripping our own
# Stop hook (stop-pre-push-review.sh), which on main with no diff would
# exit 2 and fail the reviewer for the wrong reason.
SKIP_REVIEW=1 claude -p "$REVIEW_PROMPT" \
  --permission-mode acceptEdits \
  --output-format json \
  --model "$REVIEWER_MODEL" \
  --max-turns "$REVIEWER_MAX_TURNS" \
  --disallowed-tools "$DISALLOWED" \
  > "$RUN_OUT"
CLAUDE_EXIT=$?

if [ $CLAUDE_EXIT -ne 0 ]; then
  echo "review-pr: claude -p exited $CLAUDE_EXIT" >&2
  echo "review-pr: tail of output:" >&2
  tail -20 "$RUN_OUT" >&2
  exit 2
fi

# Extract the reviewer's text result (the final assistant message body).
RESULT_TEXT=$(jq -r '.result // empty' "$RUN_OUT" 2>/dev/null)
if [ -z "$RESULT_TEXT" ]; then
  echo "review-pr: claude output had no .result field" >&2
  exit 2
fi

# The reviewer prompt says "no markdown fences"; strip them defensively
# in case the model wrapped the JSON anyway.
VERDICT_JSON=$(echo "$RESULT_TEXT" \
  | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//' \
  | jq -c '.' 2>/dev/null)

if [ -z "$VERDICT_JSON" ]; then
  echo "review-pr: reviewer output was not valid JSON" >&2
  echo "review-pr: raw result:" >&2
  printf '%s\n' "$RESULT_TEXT" | head -40 >&2
  exit 2
fi

# ---- Classify findings ----
HAS_SAFETY=$(echo "$VERDICT_JSON" | jq '[.findings[]? | select(.severity == "safety_block")] | length')
HAS_BLOCKER=$(echo "$VERDICT_JSON" | jq '[.findings[]? | select(.severity == "blocker")] | length')
SUMMARY=$(echo "$VERDICT_JSON" | jq -r '.summary // "(no summary)"')

if [ "$HAS_SAFETY" -gt 0 ]; then
  EVENT="REQUEST_CHANGES"
  VERDICT_LINE="safety-block ($HAS_SAFETY safety, $HAS_BLOCKER blocker)"
elif [ "$HAS_BLOCKER" -gt 0 ]; then
  EVENT="REQUEST_CHANGES"
  VERDICT_LINE="request-changes ($HAS_BLOCKER blocker)"
else
  EVENT="APPROVE"
  VERDICT_LINE="approved"
fi

# ---- Build inline comments (file+line) and orphan findings (top-level body) ----
INLINE_COMMENTS=$(echo "$VERDICT_JSON" | jq '[
  .findings[]?
  | select(.file != null and .line != null and (.line | type) == "number")
  | {
      path: .file,
      line: .line,
      side: "RIGHT",
      body: ("**" + .severity + "**: " + .issue
             + (if .suggestion then "\n\nSuggestion: " + .suggestion else "" end))
    }
]')

ORPHAN_FINDINGS=$(echo "$VERDICT_JSON" | jq -r '[
  .findings[]?
  | select(.file == null or .line == null or (.line | type) != "number")
  | "- **" + .severity + "**" + (if .file then " (" + .file + ")" else "" end)
    + ": " + .issue
    + (if .suggestion then " — _" + .suggestion + "_" else "" end)
] | join("\n")')

# Compose review body
REVIEW_BODY=$(cat <<EOF
**Orchestrator review** (iteration $NEW_ITER, sha \`${HEAD_OID:0:8}\`)

$SUMMARY

EOF
)
if [ -n "$ORPHAN_FINDINGS" ]; then
  REVIEW_BODY="${REVIEW_BODY}

### Findings not anchored to a line

${ORPHAN_FINDINGS}
"
fi

# ---- Post the review via gh api ----
# Single API call: POST .../pulls/<N>/reviews with event + comments[].
REVIEW_PAYLOAD=$(jq -n \
  --arg commit_id "$HEAD_OID" \
  --arg event "$EVENT" \
  --arg body "$REVIEW_BODY" \
  --argjson comments "$INLINE_COMMENTS" \
  '{commit_id: $commit_id, event: $event, body: $body, comments: $comments}')

REVIEW_RESPONSE=$(echo "$REVIEW_PAYLOAD" \
  | gh api "repos/$REPO/pulls/$PR_NUM/reviews" \
      --method POST \
      --input - 2>&1) || {
  echo "review-pr: failed to post review" >&2
  echo "$REVIEW_RESPONSE" >&2
  exit 1
}

REVIEW_ID=$(echo "$REVIEW_RESPONSE" | jq -r '.id // "?"' 2>/dev/null || echo "?")

# ---- Apply orch:safety-block label if needed ----
if [ "$HAS_SAFETY" -gt 0 ]; then
  if gh label list --repo "$REPO" --search "orch:safety-block" 2>/dev/null | grep -q 'orch:safety-block'; then
    gh pr edit "$PR_NUM" --repo "$REPO" --add-label "orch:safety-block" >/dev/null 2>&1 \
      || echo "review-pr: warning — failed to apply orch:safety-block label" >&2
  else
    echo "review-pr: warning — orch:safety-block label missing on repo; skipping label apply" >&2
  fi
fi

# ---- Update PR body with iteration markers ----
# Strip prior markers, append new ones. Idempotent on rerun.
CLEAN_BODY=$(printf '%s\n' "$PR_BODY" \
  | sed -E '/<!-- orch:review-iter:[0-9]+ -->/d' \
  | sed -E '/<!-- orch:review-iter-sha:[a-f0-9]+ -->/d')

NEW_PR_BODY=$(cat <<EOF
$CLEAN_BODY

<!-- orch:review-iter:$NEW_ITER -->
<!-- orch:review-iter-sha:$HEAD_OID -->
EOF
)

gh pr edit "$PR_NUM" --repo "$REPO" --body "$NEW_PR_BODY" >/dev/null 2>&1 \
  || echo "review-pr: warning — failed to update PR body with iteration markers" >&2

# ---- Done ----
echo "review-pr: posted $VERDICT_LINE review (id=$REVIEW_ID) on PR #$PR_NUM"
echo "  summary: $SUMMARY"
echo "  iteration: $NEW_ITER"
echo "  sha: $HEAD_OID"
exit 0
