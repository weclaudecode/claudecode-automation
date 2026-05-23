#!/usr/bin/env bash
# Create one GitHub issue per task from a plan's state.json.
#
# Usage: create-issues.sh <state-file> [<owner/repo>]
#
# Idempotent — skips tasks whose tasks.N.issue is already set in state.
# Per-plan label (orch:plan-NN) is created on first run; static orch:*
# labels must already exist (run setup-labels.sh first).
#
# Two passes:
#   1. Create all issues (writes issue numbers back to state.json)
#   2. Edit bodies to insert "Depends on issues: #X, #Y" footer using
#      the issue numbers resolved in pass 1
#
# Labels applied at creation:
#   orch:task              (always)
#   orch:plan-NN           (always; created if missing)
#   orch:deps-met          (iff depends_on is empty)
#   orch:needs-robbie      (iff task is in auto_merge_overrides)

set -euo pipefail

command -v jq >/dev/null || { echo "create-issues: jq required" >&2; exit 1; }
command -v gh >/dev/null || { echo "create-issues: gh required" >&2; exit 1; }
command -v gawk >/dev/null || { echo "create-issues: gawk required" >&2; exit 1; }

if [ $# -lt 1 ]; then
  echo "usage: $0 <state-file> [<owner/repo>]" >&2
  exit 1
fi

STATE_FILE="$1"
REPO="${2:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"

[ -f "$STATE_FILE" ] || { echo "state file not found: $STATE_FILE" >&2; exit 1; }
[ -n "$REPO" ] || {
  echo "no repo specified and gh auto-detect failed" >&2
  echo "  pass <owner/repo> as 2nd arg or run from a gh-tracked clone" >&2
  exit 1
}

PLAN_FILE=$(jq -r '.plan_file' "$STATE_FILE")
[ -f "$PLAN_FILE" ] || { echo "plan file referenced by state not found: $PLAN_FILE" >&2; exit 1; }

PLAN_BASE=$(basename "$PLAN_FILE" .md)
PLAN_NUM=$(echo "$PLAN_BASE" | grep -oE 'PLAN-[0-9]+' | grep -oE '[0-9]+' || echo "00")
TOTAL=$(jq -r '.total_tasks' "$STATE_FILE")
TASK_NUMS=$(jq -r '.tasks | keys | .[]' "$STATE_FILE" | sort -n)

echo "Creating issues for $PLAN_BASE on $REPO..."

# Per-plan label (idempotent; --force upserts)
gh label create "orch:plan-$PLAN_NUM" --color "1d76db" \
  --description "Tasks belonging to $PLAN_BASE" \
  --repo "$REPO" --force >/dev/null 2>&1 || true

# Helper: extract verbatim task section from plan file (fence-aware so
# `## Task` literals in code blocks don't break the boundary).
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

# ---- Pass 1: create issues ----
for task_num in $TASK_NUMS; do
  EXISTING=$(jq -r ".tasks[\"$task_num\"].issue" "$STATE_FILE")
  if [ "$EXISTING" != "null" ] && [ -n "$EXISTING" ]; then
    echo "  task $task_num: already has issue #$EXISTING, skipping"
    continue
  fi

  TITLE=$(jq -r ".tasks[\"$task_num\"].title" "$STATE_FILE")
  DEPS_LEN=$(jq -r ".tasks[\"$task_num\"].depends_on | length" "$STATE_FILE")
  # Use has() not `// null` — jq's `//` treats `false` as falsy and
  # would return null when the override value is literally false.
  IS_FLAGGED=$(jq -r ".auto_merge_overrides | has(\"$task_num\")" "$STATE_FILE")

  TASK_BODY=$(extract_task_body "$task_num")

  BODY=$(cat <<EOF
$TASK_BODY

---

<!-- orch:plan-num:$PLAN_NUM -->
<!-- orch:task-num:$task_num -->

**Plan:** \`$PLAN_BASE\`
**Task:** $task_num of $TOTAL
EOF
)

  # Build label list. gh accepts comma-separated.
  LABELS="orch:task,orch:plan-$PLAN_NUM"
  [ "$DEPS_LEN" -eq 0 ] && LABELS="$LABELS,orch:deps-met"
  [ "$IS_FLAGGED" = "true" ] && LABELS="$LABELS,orch:needs-robbie"

  ISSUE_URL=$(gh issue create \
    --repo "$REPO" \
    --title "[plan-$PLAN_NUM/t$task_num] $TITLE" \
    --body "$BODY" \
    --label "$LABELS")
  ISSUE_NUM=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')

  echo "  task $task_num: created #$ISSUE_NUM"

  # Write issue number back into state atomically
  TMP=$(mktemp)
  jq ".tasks[\"$task_num\"].issue = $ISSUE_NUM" "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"
done

# ---- Pass 2: insert dep-link footer ----
for task_num in $TASK_NUMS; do
  DEPS=$(jq -r ".tasks[\"$task_num\"].depends_on | .[]?" "$STATE_FILE")
  [ -z "$DEPS" ] && continue

  ISSUE_NUM=$(jq -r ".tasks[\"$task_num\"].issue" "$STATE_FILE")
  [ "$ISSUE_NUM" = "null" ] && continue

  # Resolve dep task numbers to issue numbers
  DEP_LINKS=""
  for dep in $DEPS; do
    DEP_ISSUE=$(jq -r ".tasks[\"$dep\"].issue" "$STATE_FILE")
    [ -n "$DEP_LINKS" ] && DEP_LINKS="$DEP_LINKS, "
    DEP_LINKS="${DEP_LINKS}#$DEP_ISSUE"
  done

  # Read current body, append (idempotent via marker)
  CURRENT_BODY=$(gh issue view "$ISSUE_NUM" --repo "$REPO" --json body -q .body)

  # If footer already there from a prior run, replace it; otherwise append
  if echo "$CURRENT_BODY" | grep -q "^\*\*Depends on issues:\*\*"; then
    NEW_BODY=$(echo "$CURRENT_BODY" | sed "s|^\*\*Depends on issues:\*\*.*|**Depends on issues:** $DEP_LINKS|")
  else
    NEW_BODY="${CURRENT_BODY}
**Depends on issues:** $DEP_LINKS"
  fi

  gh issue edit "$ISSUE_NUM" --repo "$REPO" --body "$NEW_BODY" >/dev/null
  echo "  task $task_num (#$ISSUE_NUM): linked deps $DEP_LINKS"
done

echo
echo "Done. State file updated: $STATE_FILE"
