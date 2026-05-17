#!/usr/bin/env bash
# Stop hook: runs the pre-push reviewer in a fresh claude -p invocation.
# - Exit 0  → allow stop, worker is done
# - Exit 2  → block stop with reviewer findings on stderr; worker iterates
#
# Reads from stdin: the JSON Claude Code passes to Stop hooks.
# Reads from disk: active plan state file under .claude/plans/*.state.json
#
# Skips review entirely if:
#   - SKIP_REVIEW=1 env var is set (useful for human debugging sessions)
#   - No plan state file exists (interactive session, not orchestrator-driven)
#   - The diff is empty (worker made no changes)

set -uo pipefail

# Always allow Stop in human-driven sessions
[ "${SKIP_REVIEW:-0}" = "1" ] && exit 0

REPO=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$REPO"

# Find the active plan state file (oldest in_progress one)
STATE_FILE=$(ls -t .claude/plans/*.state.json 2>/dev/null \
  | xargs -I {} sh -c 'jq -er ".status == \"in_progress\"" {} >/dev/null 2>&1 && echo {}' \
  | tail -1)

if [ -z "$STATE_FILE" ]; then
  exit 0  # not orchestrator-driven, allow stop
fi

CURRENT=$(jq -r '.current_task' "$STATE_FILE")
PLAN_FILE=$(jq -r '.plan_file' "$STATE_FILE")

if [ ! -f "$PLAN_FILE" ]; then
  echo "reviewer hook: plan file $PLAN_FILE not found" >&2
  exit 0  # don't block on hook bugs
fi

# Extract just the current task's section from the plan
TASK_CONTENT=$(awk -v task="## Task ${CURRENT}:" '
  $0 ~ "^" task {found=1; print; next}
  found && /^## Task / {exit}
  found && /^## / && !/^## Task / {exit}
  found {print}
' "$PLAN_FILE")

if [ -z "$TASK_CONTENT" ]; then
  echo "reviewer hook: could not find Task $CURRENT in plan" >&2
  exit 0
fi

# Get the diff. If nothing changed, nothing to review.
DIFF=$(git diff main...HEAD 2>/dev/null || git diff HEAD)
if [ -z "$DIFF" ]; then
  exit 0
fi

# Bound diff size — reviewer doesn't need 50k lines
DIFF_TRIMMED=$(echo "$DIFF" | head -c 80000)

REVIEW_PROMPT_FILE=".claude/prompts/reviewer-system.md"
[ ! -f "$REVIEW_PROMPT_FILE" ] && exit 0

# Run reviewer in a fresh claude -p process. Sonnet keeps cost down.
RESPONSE=$(claude -p "$(cat "$REVIEW_PROMPT_FILE")

## Task spec

${TASK_CONTENT}

## Diff

\`\`\`diff
${DIFF_TRIMMED}
\`\`\`" \
  --output-format json \
  --model sonnet 2>&1) || {
    echo "reviewer hook: claude -p failed, allowing stop" >&2
    exit 0  # don't block on infrastructure issues
  }

# claude -p --output-format json wraps the model's text in .result
REVIEW_TEXT=$(echo "$RESPONSE" | jq -r '.result // empty' 2>/dev/null)
[ -z "$REVIEW_TEXT" ] && REVIEW_TEXT="$RESPONSE"

# Strip possible markdown fences the model might add
REVIEW_TEXT=$(echo "$REVIEW_TEXT" | sed -e 's/^```json//' -e 's/```$//' | tr -d '\r')

# Did it pass?
PASS=$(echo "$REVIEW_TEXT" | jq -r '.pass // false' 2>/dev/null || echo "false")

if [ "$PASS" = "true" ]; then
  exit 0
fi

# Extract blocker findings (only blockers actually block stop)
BLOCKERS=$(echo "$REVIEW_TEXT" \
  | jq -r '.findings[]? | select(.severity == "blocker") | "- \(.file // "?"):\(.line // "?")  \(.issue) — fix: \(.suggestion // "")"' \
  2>/dev/null)

if [ -z "$BLOCKERS" ]; then
  # No blockers means we accept it
  exit 0
fi

cat >&2 <<EOF
PRE-PUSH REVIEWER BLOCKED

The reviewer found issues that must be fixed before this task can be
considered complete. Address these and continue:

$BLOCKERS

EOF

exit 2  # exit 2 in Stop hook blocks stop and feeds stderr to the model
