#!/usr/bin/env bash
# Ingest a superpower-style plan markdown file into orchestrator state.
#
# Usage: ingest-plan.sh <plan.md>
#
# Output: writes <plan>.state.json next to the plan with:
#   - plan_file, total_tasks, status, ingested_at
#   - tasks: object keyed by task number with depends_on/touches/status/...
#   - auto_merge_overrides: { "<task_num>": false } for sensitive tasks
#
# Validates the spec at orchestrator-kit/docs/PLAN-FORMAT.md:
#   - Every task has **depends_on:** and **touches:** fields
#   - touches: is non-empty
#   - depends_on: references real tasks; no self-deps
#   - No cycles in the dependency graph
#
# Exit codes:
#   0  ingested cleanly
#   1  validation or environment failure (no state file written)

set -euo pipefail

# ---- Dependency checks ----
GAWK=$(command -v gawk) || {
  echo "ingest-plan: gawk required" >&2
  echo "  macOS: brew install gawk" >&2
  echo "  Linux: apt-get install gawk (or equivalent)" >&2
  echo "BSD awk silently no-ops match() array capture, breaking parsing." >&2
  exit 1
}
command -v jq >/dev/null || { echo "ingest-plan: jq required" >&2; exit 1; }
command -v python3 >/dev/null || {
  echo "ingest-plan: python3 required (used for dep-cycle detection)" >&2
  exit 1
}

# ---- Args ----
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

# ---- Pass 0: optional YAML frontmatter ----
# Recognized keys (extend cautiously — frontmatter is an exception path, not
# the primary config surface):
#   auto_recommended: true|false   per-plan override of $ORCH_AUTO_RECOMMENDED
#                                  (Task 3.4); evaluated per-task at spawn time.
#
# Frontmatter must start on line 1 with `---` and close with `---` on its own
# line; otherwise the document is treated as having no frontmatter. Unknown
# keys are silently ignored so future versions can add fields without
# breaking older ingest scripts.
# Emit the raw value (whatever follows `auto_recommended:`) so the case
# statement below catches bad values like `yes`/`on` instead of silently
# treating them as the default. The silent-failure mode is exactly what
# this kit's CLAUDE.md warns about for ingest parsing.
AUTO_REC=$("$GAWK" '
  NR == 1 { if ($0 != "---") exit; in_fm = 1; next }
  /^---$/ && in_fm { exit }
  in_fm && /^auto_recommended:/ {
    sub(/^auto_recommended:[[:space:]]*/, "")
    sub(/[[:space:]]*$/, "")
    print
  }
' "$PLAN")

case "$AUTO_REC" in
  true)  AUTO_REC_JSON="true" ;;
  false) AUTO_REC_JSON="false" ;;
  "")    AUTO_REC_JSON="false" ;;
  *)
    echo "ingest-plan: invalid auto_recommended value '$AUTO_REC' (expected true|false)" >&2
    exit 1
    ;;
esac

# ---- Pass 1: parse tasks ----
# Per-task gawk pass emits one JSON object per line with fields parsed
# from the task header. Validation happens in a second pass so we can
# report all problems at once.
TASKS_JSON=$("$GAWK" '
  function emit_task() {
    if (current_task == "") return
    printf "{\"task\": %s, \"title\": \"%s\", \"depends_on\": [%s], \"touches\": [%s]",
      current_task, title, depends_on, touches_json
    if (auto_merge_set) printf ", \"auto_merge\": %s", auto_merge_value
    if (max_turns_set) printf ", \"max_turns\": %s", max_turns_value
    printf "}\n"
  }
  BEGIN { in_fence = 0; current_task = ""; depends_on = ""; touches_json = ""; auto_merge_set = 0; max_turns_set = 0 }
  /^```/ { in_fence = !in_fence; next }
  in_fence { next }
  /^## Task [0-9]+:/ {
    emit_task()
    match($0, /Task ([0-9]+):[[:space:]]*(.*)/, m)
    current_task = m[1]
    title = m[2]
    gsub(/"/, "\\\"", title)
    depends_on = ""
    touches_json = ""
    auto_merge_set = 0
    auto_merge_value = ""
    max_turns_set = 0
    max_turns_value = ""
    next
  }
  /^## / && current_task != "" {
    emit_task()
    current_task = ""
    next
  }
  current_task != "" && /^\*\*depends_on:\*\*/ {
    if (match($0, /\[([^\]]*)\]/, d) > 0) {
      depends_on = d[1]
      gsub(/[[:space:]]/, "", depends_on)
    }
    next
  }
  current_task != "" && /^\*\*touches:\*\*/ {
    if (match($0, /\[([^\]]*)\]/, t) > 0) {
      touches_json = t[1]
      gsub(/`/, "\"", touches_json)
    }
    next
  }
  current_task != "" && /^\*\*auto_merge:\*\*/ {
    if (match($0, /\*\*auto_merge:\*\*[[:space:]]*([a-zA-Z]+)/, a) > 0) {
      auto_merge_set = 1
      auto_merge_value = a[1]
    }
    next
  }
  current_task != "" && /^\*\*max_turns:\*\*/ {
    if (match($0, /\*\*max_turns:\*\*[[:space:]]*([0-9]+)/, mt) > 0) {
      max_turns_set = 1
      max_turns_value = mt[1]
    }
    next
  }
  END { emit_task() }
' "$PLAN")

TOTAL=$(printf '%s\n' "$TASKS_JSON" | grep -c . || true)
if [ "$TOTAL" -eq 0 ]; then
  echo "no '## Task N:' headers found in $PLAN" >&2
  exit 1
fi

# Validate each task's JSON parses (catches malformed gawk output early)
if ! printf '%s\n' "$TASKS_JSON" | jq -e . >/dev/null 2>&1; then
  echo "ingest-plan: parser produced invalid JSON. Plan file may have unusual characters." >&2
  echo "Parser output:" >&2
  printf '%s\n' "$TASKS_JSON" | sed 's/^/  /' >&2
  exit 1
fi

# ---- Pass 2: validate ----
ALL_TASKS=$(printf '%s\n' "$TASKS_JSON" | jq -r '.task' | sort -n)
VALIDATION_FAILED=0

while IFS= read -r task_line; do
  task_num=$(echo "$task_line" | jq -r '.task')
  touches_len=$(echo "$task_line" | jq -r '.touches | length')

  if [ "$touches_len" -eq 0 ]; then
    echo "task $task_num: **touches:** must be present and non-empty" >&2
    VALIDATION_FAILED=1
  fi

  # depends_on validation
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    if ! echo "$ALL_TASKS" | grep -qFx "$dep"; then
      echo "task $task_num: depends_on references nonexistent task $dep" >&2
      VALIDATION_FAILED=1
    fi
    if [ "$dep" = "$task_num" ]; then
      echo "task $task_num: depends_on includes itself" >&2
      VALIDATION_FAILED=1
    fi
  done < <(echo "$task_line" | jq -r '.depends_on[]?')
done <<< "$TASKS_JSON"

[ "$VALIDATION_FAILED" -eq 1 ] && exit 1

# Cycle detection via DFS in python (gawk + bash struggle with graph algos)
if ! printf '%s\n' "$TASKS_JSON" | python3 -c '
import json, sys
tasks = [json.loads(line) for line in sys.stdin if line.strip()]
graph = {t["task"]: list(t["depends_on"]) for t in tasks}
WHITE, GRAY, BLACK = 0, 1, 2
color = {n: WHITE for n in graph}
def visit(n, path):
    if color.get(n) == GRAY:
        cycle = path[path.index(n):] + [n]
        print("cycle: " + " -> ".join(map(str, cycle)), file=sys.stderr)
        return False
    if color.get(n) == BLACK:
        return True
    color[n] = GRAY
    for m in graph.get(n, []):
        if not visit(m, path + [n]):
            return False
    color[n] = BLACK
    return True
for n in list(graph):
    if color[n] == WHITE:
        if not visit(n, []):
            sys.exit(1)
'; then
  exit 1
fi

# ---- Pass 3: sensitive-pattern auto-flag ----
# Patterns are POSIX ERE. \. → [.], \* → [*]. Substring match (no \b);
# err toward false positives so a task that mentions "KMS" in passing
# gets flagged rather than missing one that genuinely touches a KMS key.
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
PATTERN=$(IFS='|'; echo "${SENSITIVE_PATTERNS[*]}")

PATTERN_FLAGGED=$("$GAWK" -v pat="$PATTERN" '
  BEGIN { in_fence = 0; current_task = ""; hit = 0 }
  /^```/ { in_fence = !in_fence; next }
  in_fence { next }
  /^## Task [0-9]+:/ {
    if (current_task != "" && hit) print current_task
    match($0, /Task ([0-9]+)/, m)
    current_task = m[1]
    hit = 0
    next
  }
  /^## / && current_task != "" {
    if (hit) print current_task
    current_task = ""
    hit = 0
    next
  }
  current_task != "" && $0 ~ pat { hit = 1 }
  END { if (current_task != "" && hit) print current_task }
' "$PLAN")

# Combine pattern-flagged + explicit auto_merge:false from headers
OVERRIDES=$(
  {
    while IFS= read -r t; do
      [ -z "$t" ] && continue
      printf '{"%s": false}\n' "$t"
    done <<< "$PATTERN_FLAGGED"
    printf '%s\n' "$TASKS_JSON" | jq -c 'select(.auto_merge == false) | {(.task | tostring): false}'
  } | jq -s 'add // {}'
)

# ---- Build state.json ----
TASKS_OBJECT=$(printf '%s\n' "$TASKS_JSON" | jq -s '
  reduce .[] as $t ({}; .[$t.task | tostring] = (
    {
      title: $t.title,
      depends_on: $t.depends_on,
      touches: $t.touches,
      issue: null,
      pr: null,
      status: "pending",
      retries: 0
    }
    + (if $t | has("max_turns") then {max_turns: $t.max_turns} else {} end)
  ))
')

jq -n \
  --arg plan_file "$PLAN" \
  --argjson total "$TOTAL" \
  --argjson tasks "$TASKS_OBJECT" \
  --argjson overrides "$OVERRIDES" \
  --argjson auto_rec "$AUTO_REC_JSON" \
  '{
    plan_file: $plan_file,
    total_tasks: $total,
    status: "in_progress",
    tasks: $tasks,
    auto_merge_overrides: $overrides,
    auto_recommended: $auto_rec,
    ingested_at: (now | todateiso8601)
  }' > "$STATE_FILE"

# ---- Summary ----
echo "Ingested: $PLAN"
echo "  Tasks:                $TOTAL"
echo "  Auto-merge disabled:  $(echo "$OVERRIDES" | jq -r 'keys | join(", ") // "none"')"
echo "  Auto-recommended:     $AUTO_REC_JSON"
echo "  State file:           $STATE_FILE"
echo
echo "Review the state file, edit auto_merge_overrides if needed, then create issues:"
echo "  .claude/scripts/create-issues.sh $STATE_FILE"
