#!/usr/bin/env bash
# Ingest a superpower plan markdown file into orchestrator state.
#
# Usage: .claude/scripts/ingest-plan.sh path/to/plan.md
#
# Output: writes <plan>.state.json next to the plan with:
#   - current_task: 1
#   - total_tasks: count of `## Task N:` headers
#   - retries_for_current: 0
#   - status: in_progress
#   - auto_merge_overrides: { "<task_num>": false } for tasks that touch
#     IAM, infra, migrations, security-sensitive paths

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <plan.md>" >&2
  exit 1
fi

PLAN="$1"
[ ! -f "$PLAN" ] && { echo "plan not found: $PLAN" >&2; exit 1; }

PLAN_DIR=$(dirname "$PLAN")
PLAN_BASE=$(basename "$PLAN" .md)
STATE_FILE="$PLAN_DIR/${PLAN_BASE}.state.json"

if [ -f "$STATE_FILE" ]; then
  echo "state file already exists: $STATE_FILE" >&2
  echo "delete it first if you want to re-ingest" >&2
  exit 1
fi

# Count tasks
TOTAL=$(grep -cE '^## Task [0-9]+' "$PLAN" || echo 0)
[ "$TOTAL" -eq 0 ] && { echo "no '## Task N' headers found in $PLAN" >&2; exit 1; }

# Identify tasks that touch security-sensitive areas. We scan each task's
# section for these patterns and flag the task number for manual review.
SENSITIVE_PATTERNS=(
  'IAM'
  'iam\.PolicyStatement'
  'iam\.Role'
  'aws_iam_role'
  'infra/'
  'terraform/prod'
  'migrations?/'
  'schema\.sql'
  'PolicyDocument'
  'AssumeRole'
  'Effect.*Deny'
  'Effect.*Allow'
  'Guardrail'
  'Secret'
  'KMS'
  'security-group'
  'SecurityGroup'
  '\.github/workflows/'
)

# Build a single regex
PATTERN=$(IFS='|'; echo "${SENSITIVE_PATTERNS[*]}")

# Walk tasks: for each, capture its section and check for sensitive patterns
NEEDS_REVIEW=()
awk -v pat="$PATTERN" '
  /^## Task [0-9]+/ {
    if (current_task != "" && hit) {
      print current_task
    }
    match($0, /Task ([0-9]+)/, m)
    current_task = m[1]
    hit = 0
    next
  }
  /^## / && !/^## Task / {
    if (current_task != "" && hit) {
      print current_task
    }
    current_task = ""
    hit = 0
    next
  }
  current_task != "" {
    if ($0 ~ pat) hit = 1
  }
  END {
    if (current_task != "" && hit) print current_task
  }
' "$PLAN" | while read -r t; do
  echo "  task $t flagged for manual review"
  NEEDS_REVIEW+=("$t")
done > /tmp/ingest_flagged.$$

# Read flagged tasks back
FLAGGED=$(cat /tmp/ingest_flagged.$$ 2>/dev/null || true)
rm -f /tmp/ingest_flagged.$$

# Build auto_merge_overrides JSON object
OVERRIDES="{}"
if [ -n "$FLAGGED" ]; then
  # Parse "  task N flagged" lines back to numbers and build JSON
  TASK_NUMS=$(echo "$FLAGGED" | awk '{print $2}')
  OVERRIDES=$(echo "$TASK_NUMS" | jq -R . | jq -s 'map({(.): false}) | add // {}')
fi

# Write state file
jq -n \
  --arg plan_file "$PLAN" \
  --argjson total "$TOTAL" \
  --argjson overrides "$OVERRIDES" \
  '{
    plan_file: $plan_file,
    current_task: 1,
    total_tasks: $total,
    retries_for_current: 0,
    status: "in_progress",
    auto_merge_overrides: $overrides,
    ingested_at: (now | todateiso8601)
  }' > "$STATE_FILE"

echo
echo "Ingested: $PLAN"
echo "  Total tasks:    $TOTAL"
echo "  State file:     $STATE_FILE"
echo "  Manual review:  $(echo "$OVERRIDES" | jq -r 'keys | join(", ") // "none"')"
echo
echo "Review the state file, edit auto_merge_overrides if needed, then start the loop."
