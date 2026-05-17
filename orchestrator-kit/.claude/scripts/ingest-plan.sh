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

GAWK=$(command -v gawk) || {
  echo "ingest-plan: gawk required" >&2
  echo "  macOS: brew install gawk" >&2
  echo "  Linux: apt-get install gawk (or equivalent)" >&2
  echo "BSD awk silently no-ops match() array capture, breaking pattern detection." >&2
  exit 1
}

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

# Count tasks (fence-aware: skip `## Task` lines inside code blocks)
TOTAL=$("$GAWK" '
  /^```/ { in_fence = !in_fence; next }
  in_fence { next }
  /^## Task [0-9]+/ { count++ }
  END { print count + 0 }
' "$PLAN")
[ "$TOTAL" -eq 0 ] && { echo "no '## Task N' headers found in $PLAN" >&2; exit 1; }

# Identify tasks that touch security-sensitive areas. We scan each task's
# section for these patterns and flag the task number for manual review.
# Patterns are POSIX ERE, passed to gawk via -v (which applies C-escape
# processing). Avoid backslash escapes that would be eaten by -v:
#   \. → [.]   (literal dot)
#   \* → [*]   (literal asterisk)
#   \b → no boundary; rely on substring match. Err toward false positives:
#        better to flag a task that mentions "KMS" in passing than miss one
#        that genuinely modifies a KMS key.
SENSITIVE_PATTERNS=(
  'IAM'
  'aws_iam_'
  'iam[.]PolicyStatement'
  'iam[.]Role'
  'PolicyDocument'
  'AssumeRole'
  '"Effect"'
  'Principal[[:space:]]*[:=][[:space:]]*"[*]"'
  '0[.]0[.]0[.]0/0'
  'public_?access'
  'PublicAccessBlock'
  'BucketPolicy'
  'FunctionUrl'
  'KMS'
  'SecretsManager'
  'security[_-]group'
  'NetworkAcl'
  'migrations?/'
  'schema[.]sql'
  '[Aa]lter [Tt]able'
  '[Dd]rop [Cc]olumn'
  '[.]github/workflows/'
  'terraform/(prod|production)/'
  'infra/'
)

# Build a single regex
PATTERN=$(IFS='|'; echo "${SENSITIVE_PATTERNS[*]}")

# Walk tasks: for each, capture its section and check for sensitive patterns.
# Fence tracking prevents `## Task` literals inside code blocks from being
# treated as section headers.
NEEDS_REVIEW=()
"$GAWK" -v pat="$PATTERN" '
  /^```/ { in_fence = !in_fence; next }
  in_fence { next }
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
