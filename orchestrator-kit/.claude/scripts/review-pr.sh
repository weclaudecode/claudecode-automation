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
#   <!-- orch:review-sha:<headOid> -->
#
# Exit codes:
#   0  review posted (approve OR request-changes) OR non-JSON fallback applied
#      (orch:review-sha marker + orch:review-blocked label + explanatory
#      comment on the PR — fallback_non_json_review in _dispatcher_lib.sh)
#   1  environment / args / lookup failure
#   2  reviewer ran but produced no result entry at all (no fallback possible)

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

# shellcheck source=_dispatcher_lib.sh
source "$REPO_ROOT/.claude/scripts/_dispatcher_lib.sh"

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

# Structured acceptance criteria (if declared). Surfaced explicitly to the
# reviewer so an unmet criterion becomes a deterministic blocker rather than
# something the reviewer has to infer from the prose spec. Empty when absent.
ACCEPTANCE_SECTION=$(jq -r --arg t "$TASK_NUM" '
  (.tasks[$t].acceptance // [])
  | if length > 0
    then "## Acceptance criteria (verify each against the diff)\n\n"
         + ([ to_entries[] | "\(.key + 1). \(.value)" ] | join("\n"))
         + "\n\nEach criterion the diff does not satisfy is a `blocker` finding."
    else "" end
' "$STATE_FILE" 2>/dev/null || echo "")

# ---- Fetch PR diff ----
PR_DIFF=$(gh pr diff "$PR_NUM" --repo "$REPO" 2>/dev/null) || {
  echo "review-pr: failed to fetch diff for PR #$PR_NUM" >&2
  exit 1
}

if [ -z "$PR_DIFF" ]; then
  echo "review-pr: PR #$PR_NUM has an empty diff — refusing to review" >&2
  exit 1
fi

# Persist the diff so the parallel pr-review-toolkit subagents can each
# Read it once instead of getting it inlined six times in their prompts.
# Path is namespaced by PR + HEAD sha so concurrent reviews on different
# PRs don't trample each other.
DIFF_DIR="$REPO_ROOT/.claude/state"
mkdir -p "$DIFF_DIR"
DIFF_PATH="$DIFF_DIR/review-pr${PR_NUM}-sha${HEAD_OID:0:12}.diff"
printf '%s\n' "$PR_DIFF" > "$DIFF_PATH" || {
  echo "review-pr: failed to write diff to $DIFF_PATH" >&2
  exit 1
}

# ---- Read prior iteration count from PR body ----
PRIOR_ITER=$(echo "$PR_BODY" | grep -oE 'orch:review-iter:[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "0")
NEW_ITER=$((PRIOR_ITER + 1))

# ---- CDK diff (only for plans with aws_env) ----
CDK_DIFF_TEXT=""
if [ "$(jq -r '.aws_env // empty' "$STATE_FILE")" != "" ]; then
  echo "review-pr: aws_env detected — running cdk-diff.sh for PR #$PR_NUM..." >&2
  CDK_DIFF_SCRIPT="$REPO_ROOT/.claude/scripts/cdk-diff.sh"
  if [ -x "$CDK_DIFF_SCRIPT" ]; then
    # Capture stdout only (structured diff text). cdk-diff's stderr is
    # operator-facing diagnostics — letting it flow to our own stderr keeps
    # the reviewer prompt clean and the tick log informative.
    CDK_DIFF_TEXT=$(bash "$CDK_DIFF_SCRIPT" "$PR_NUM" "$STATE_FILE") || {
      echo "review-pr: cdk-diff failed (exit $?) — continuing with text-only review" >&2
      CDK_DIFF_TEXT=""
    }
  else
    echo "review-pr: $CDK_DIFF_SCRIPT not found or not executable — skipping CDK diff" >&2
  fi
fi

# ---- Build reviewer prompt ----
REVIEWER_SYSTEM="$REPO_ROOT/.claude/prompts/reviewer-system.md"
[ -f "$REVIEWER_SYSTEM" ] || {
  echo "review-pr: reviewer system prompt missing: $REVIEWER_SYSTEM" >&2
  exit 1
}

# Build the optional CDK diff section (empty string when no aws_env).
CDK_DIFF_SECTION=""
if [ -n "$CDK_DIFF_TEXT" ]; then
  CDK_DIFF_SECTION=$(cat <<'CDKSECTION'

## Cloud-side delta (from `cdk diff`)

The following CDK diff was captured from the PR head and posted as a comment
on the PR. Subagents that review for IAM widening, destructive changes, or
region drift should read this section carefully.

CDKSECTION
  )
  CDK_DIFF_SECTION="${CDK_DIFF_SECTION}${CDK_DIFF_TEXT}"
fi

REVIEW_PROMPT=$(cat <<EOF
$(cat "$REVIEWER_SYSTEM")

---

## Coordinator inputs

- REPO_SLUG: $REPO
- PR_NUM:    $PR_NUM
- DIFF_PATH: $DIFF_PATH
- Iteration: $NEW_ITER
${CDK_DIFF_SECTION}

## Task spec (verbatim from plan)

$TASK_SPEC

${ACCEPTANCE_SECTION}

---

## Reminder

Dispatch the six pr-review-toolkit specialists in parallel via Task, plus
\`/security-review\` via Skill. Aggregate. Return ONLY the JSON verdict
object specified above. No prose, no markdown fences around it.
EOF
)

# ---- Spawn reviewer ----
REVIEWER_MODEL="${ORCH_REVIEWER_MODEL:-opus}"
REVIEWER_MAX_TURNS="${ORCH_REVIEWER_MAX_TURNS:-20}"
REVIEWER_TIMEOUT="${ORCH_REVIEWER_TIMEOUT:-300}"
TIMEOUT_CMD=$(find_timeout_cmd)

# Deny-list locks the reviewer to read-only. Bash(...) globs match the
# command form; the reviewer can still run `git log`, `gh api`, etc.
DISALLOWED='Edit,Write,NotebookEdit,Bash(git push:*),Bash(gh pr merge:*),Bash(gh pr close:*),Bash(gh pr edit:*),Bash(gh pr review:*),Bash(rm:*)'

if [ -n "$TIMEOUT_CMD" ]; then
  echo "review-pr: spawning reviewer (model=$REVIEWER_MODEL, iter=$NEW_ITER, sha=${HEAD_OID:0:8}, timeout=${REVIEWER_TIMEOUT}s)..."
else
  echo "review-pr: spawning reviewer (model=$REVIEWER_MODEL, iter=$NEW_ITER, sha=${HEAD_OID:0:8}, timeout=NONE — install coreutils/gtimeout)..."
fi

RUN_OUT=$(mktemp)
trap 'rm -f "$RUN_OUT"' EXIT

# SKIP_REVIEW=1 prevents this child claude -p from tripping our own
# Stop hook (stop-pre-push-review.sh), which on main with no diff would
# exit 2 and fail the reviewer for the wrong reason.
# Array form so the timeout prefix is optional without duplicating the
# claude command. timeout exit 124 is treated the same as any non-zero
# claude exit by the existing handling below.
RUN_CMD=()
if [ -n "$TIMEOUT_CMD" ]; then
  RUN_CMD=("$TIMEOUT_CMD" "${REVIEWER_TIMEOUT}s")
fi
RUN_CMD+=(env SKIP_REVIEW=1 claude -p "$REVIEW_PROMPT"
  --permission-mode acceptEdits
  --output-format json
  --model "$REVIEWER_MODEL"
  --max-turns "$REVIEWER_MAX_TURNS"
  --disallowed-tools "$DISALLOWED")

"${RUN_CMD[@]}" > "$RUN_OUT"
CLAUDE_EXIT=$?
if [ "$CLAUDE_EXIT" = "124" ] && [ -n "$TIMEOUT_CMD" ]; then
  echo "review-pr: reviewer exceeded ${REVIEWER_TIMEOUT}s timeout — treating as failure" >&2
fi

# Capture reviewer usage. Runs on every reviewer invocation including
# failed ones — reviewer costs are real and operator visibility matters.
# Safe before the exit check because extract_usage_summary returns empty
# (and exits 0) when the run JSON is malformed or missing.
USAGE_LINE=$(extract_usage_summary "$RUN_OUT")
if [ -n "$USAGE_LINE" ]; then
  echo "review-pr: usage [reviewer iter $NEW_ITER sha ${HEAD_OID:0:8}] $USAGE_LINE"
  if [ -n "${STATE_FILE:-}" ] && [ -n "${TASK_NUM:-}" ] && [ -f "$STATE_FILE" ]; then
    update_task_usage "$STATE_FILE" "$TASK_NUM" "$RUN_OUT" reviewer || \
      echo "review-pr: warning — failed to persist usage to state" >&2
  fi
  gh pr comment "$PR_NUM" --body "**Usage** (reviewer, iter $NEW_ITER, sha \`${HEAD_OID:0:8}\`): \`$USAGE_LINE\`" >/dev/null 2>&1 || \
    echo "review-pr: warning — failed to post usage comment to PR #$PR_NUM" >&2
fi

if [ $CLAUDE_EXIT -ne 0 ]; then
  echo "review-pr: claude -p exited $CLAUDE_EXIT" >&2
  echo "review-pr: tail of output:" >&2
  tail -20 "$RUN_OUT" >&2
  exit 2
fi

# Extract the reviewer's text result. `claude -p --output-format json`
# emits a JSON array of message objects; the final one has type=result
# and a .result field holding the assistant's text.
RESULT_TEXT=$(jq -r '.[] | select(.type == "result") | .result // empty' "$RUN_OUT" 2>/dev/null)
if [ -z "$RESULT_TEXT" ]; then
  echo "review-pr: claude output had no result entry" >&2
  echo "review-pr: tail of output:" >&2
  tail -20 "$RUN_OUT" >&2
  exit 2
fi

# Also surface any error flag from the result entry.
RESULT_IS_ERROR=$(jq -r '.[] | select(.type == "result") | .is_error // false' "$RUN_OUT" 2>/dev/null)
if [ "$RESULT_IS_ERROR" = "true" ]; then
  echo "review-pr: reviewer reported is_error=true" >&2
  echo "review-pr: raw result:" >&2
  printf '%s\n' "$RESULT_TEXT" | head -40 >&2
  exit 2
fi

# The reviewer prompt says "no markdown fences"; strip them defensively
# in case the model wrapped the JSON anyway.
VERDICT_JSON=$(echo "$RESULT_TEXT" \
  | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//' \
  | jq -c '.' 2>/dev/null)

if [ -z "$VERDICT_JSON" ]; then
  echo "review-pr: reviewer output was not valid JSON — invoking synthetic-blocker fallback" >&2
  echo "review-pr: raw result (first 40 lines):" >&2
  printf '%s\n' "$RESULT_TEXT" | head -40 >&2
  fallback_non_json_review "$REPO" "$PR_NUM" "$HEAD_OID" "$PR_BODY" "$RESULT_TEXT"
  exit 0
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

# GitHub limitation: a PR's author cannot post APPROVE or REQUEST_CHANGES
# reviews on their own PR (HTTP 422). When the orchestrator runs as the
# same gh identity as the worker — the common single-bot deployment — we
# fall back to COMMENT. Labels (orch:review-blocked, orch:safety-block)
# applied below carry the verdict to iterate-pass regardless of event type.
# Operators with two bot identities won't trip this branch.
PR_AUTHOR=$(gh pr view "$PR_NUM" --repo "$REPO" --json author -q .author.login 2>/dev/null || echo "")
GH_USER=$(gh api user --jq .login 2>/dev/null || echo "")
if [ -n "$PR_AUTHOR" ] && [ -n "$GH_USER" ] && [ "$PR_AUTHOR" = "$GH_USER" ] && [ "$EVENT" != "COMMENT" ]; then
  echo "review-pr: self-review detected (author=$PR_AUTHOR == user); using COMMENT event (verdict in body + labels)"
  EVENT="COMMENT"
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

# ---- Apply / remove labels based on verdict ----
# orch:safety-block on any safety finding (operator-only; never auto-iterates).
# orch:review-blocked on any regular blocker (iterate-pass.sh filter).
# On approve, remove review-blocked so iterate-pass stops considering it.
if [ "$HAS_SAFETY" -gt 0 ]; then
  if gh label list --repo "$REPO" --search "orch:safety-block" 2>/dev/null | grep -q 'orch:safety-block'; then
    gh pr edit "$PR_NUM" --repo "$REPO" --add-label "orch:safety-block" >/dev/null 2>&1 \
      || echo "review-pr: warning — failed to apply orch:safety-block label" >&2
  else
    echo "review-pr: warning — orch:safety-block label missing on repo; skipping label apply" >&2
  fi
fi

if [ "$HAS_BLOCKER" -gt 0 ]; then
  if gh label list --repo "$REPO" --search "orch:review-blocked" 2>/dev/null | grep -q 'orch:review-blocked'; then
    gh pr edit "$PR_NUM" --repo "$REPO" --add-label "orch:review-blocked" >/dev/null 2>&1 \
      || echo "review-pr: warning — failed to apply orch:review-blocked label" >&2
  else
    echo "review-pr: warning — orch:review-blocked label missing on repo; skipping label apply" >&2
  fi
elif [ "$EVENT" = "APPROVE" ]; then
  # --remove-label is a no-op (exit 0) if the label isn't on the PR, so it's
  # safe to call unconditionally on every approve.
  gh pr edit "$PR_NUM" --repo "$REPO" --remove-label "orch:review-blocked" >/dev/null 2>&1 \
    || true
fi

# PLAN-12 / closes #42: reviewer is the merge gate. On a clean verdict
# (no safety_block, no blocker), enable auto-merge for non-sensitive tasks.
# Sensitive tasks (auto_merge_overrides[N] == false) stay manual-merge —
# orch:needs-robbie was already applied by launch-worker.sh.
# Fallback path (fallback_non_json_review) exits 0 before reaching here, so
# it correctly does NOT call gh pr merge. REQUEST_CHANGES verdicts are
# filtered by the HAS_SAFETY/HAS_BLOCKER check below.
if [ "$HAS_SAFETY" -eq 0 ] && [ "$HAS_BLOCKER" -eq 0 ]; then
  maybe_enable_auto_merge "$STATE_FILE" "$TASK_NUM" "$PR_NUM" "$REPO" || true
fi

# ---- Update PR body with iteration markers ----
# Strip prior markers, append new ones. Idempotent on rerun.
CLEAN_BODY=$(printf '%s\n' "$PR_BODY" \
  | sed -E '/<!-- orch:review-iter:[0-9]+ -->/d' \
  | sed -E '/<!-- orch:review-sha:[a-f0-9]+ -->/d')

NEW_PR_BODY=$(cat <<EOF
$CLEAN_BODY

<!-- orch:review-iter:$NEW_ITER -->
<!-- orch:review-sha:$HEAD_OID -->
EOF
)

gh pr edit "$PR_NUM" --repo "$REPO" --body "$NEW_PR_BODY" >/dev/null 2>&1 \
  || echo "review-pr: warning — failed to update PR body with iteration markers" >&2

# ---- Emit structured event (best-effort; feeds events.jsonl) ----
emit_event review "$(jq -cn \
  --arg plan "$PLAN_NUM" --argjson task "$TASK_NUM" --argjson pr "$PR_NUM" \
  --arg event "$EVENT" --argjson safety "$HAS_SAFETY" --argjson blocker "$HAS_BLOCKER" \
  --argjson iter "$NEW_ITER" --arg sha "${HEAD_OID:0:12}" \
  '{plan: $plan, task: $task, pr: $pr, verdict: $event, safety_blocks: $safety, blockers: $blocker, iteration: $iter, sha: $sha}' 2>/dev/null || echo '{}')"

# ---- Done ----
echo "review-pr: posted $VERDICT_LINE review (id=$REVIEW_ID) on PR #$PR_NUM"
echo "  summary: $SUMMARY"
echo "  iteration: $NEW_ITER"
echo "  sha: $HEAD_OID"
exit 0
