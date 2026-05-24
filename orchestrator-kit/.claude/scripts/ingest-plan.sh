#!/usr/bin/env bash
# Ingest a superpower-style plan markdown file into orchestrator state.
#
# Usage: ingest-plan.sh <plan.md>
#
# Output: writes <plan>.state.json next to the plan with:
#   - schema_version, plan_file, total_tasks, status, ingested_at
#   - tasks: object keyed by task number with depends_on/touches/status/...
#   - auto_merge_overrides: { "<task_num>": false } for sensitive tasks
#   - env, aws_env, requires, pre_flight (when present in frontmatter)
#
# Validates the spec at orchestrator-kit/docs/PLAN-FORMAT.md:
#   - Every task has **depends_on:** and **touches:** fields
#   - touches: is non-empty
#   - depends_on: references real tasks; no self-deps
#   - No cycles in the dependency graph
#   - New v3 fields: deploy_mode, smoke_test, aws_env, env, requires, pre_flight
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
  echo "ingest-plan: python3 required (used for dep-cycle detection and frontmatter parsing)" >&2
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

# Derive the plan slug (e.g. "PLAN-05") from the filename for self-reference check
PLAN_SLUG=$(echo "$PLAN_BASE" | grep -oE '^PLAN-[0-9]{2}' || true)

# ---- Pass 0: optional YAML frontmatter ----
# We shell out to python3 for frontmatter parsing because nested YAML (aws:,
# pre_flight:) is intractable to implement correctly in gawk. python3 is
# already a required dep (used for cycle detection). The frontmatter block
# is extracted first with gawk (line extraction only, no parsing), then
# parsed by python3's yaml.safe_load.
#
# Recognized top-level keys: auto_recommended, env, aws, requires, pre_flight.
# Unknown keys are REJECTED (not silently ignored) — see project_kit_safety_findings.
# Note: PLAN-FORMAT.md §"Plan-level frontmatter fields" says unknown keys are
# "silently ignored", but the task spec explicitly overrides this to reject
# them as a safety policy. This implementation follows the task spec.

HAS_FRONTMATTER=$("$GAWK" 'NR==1{ print ($0 == "---") ? "yes" : "no"; exit }' "$PLAN")

FRONTMATTER_JSON="{}"
if [ "$HAS_FRONTMATTER" = "yes" ]; then
  # Extract raw YAML frontmatter (between the two --- lines) for python parsing
  FRONTMATTER_RAW=$("$GAWK" '
    NR == 1 { in_fm = 1; next }
    /^---$/ && in_fm { exit }
    in_fm { print }
  ' "$PLAN")

  # Parse with python3 yaml.safe_load → JSON; validate allowed keys
  FRONTMATTER_JSON=$(echo "$FRONTMATTER_RAW" | python3 -c '
import yaml, json, sys, re

ALLOWED_KEYS = {"auto_recommended", "env", "aws", "requires", "pre_flight"}

raw = sys.stdin.read()
if not raw.strip():
    print("{}")
    sys.exit(0)

try:
    data = yaml.safe_load(raw)
except yaml.YAMLError as e:
    print(f"ingest-plan: frontmatter YAML parse error: {e}", file=sys.stderr)
    sys.exit(1)

if data is None:
    print("{}")
    sys.exit(0)

if not isinstance(data, dict):
    print("ingest-plan: frontmatter must be a YAML mapping", file=sys.stderr)
    sys.exit(1)

# Reject unknown keys
unknown = set(data.keys()) - ALLOWED_KEYS
if unknown:
    allowed_str = ", ".join(sorted(ALLOWED_KEYS))
    for k in sorted(unknown):
        print("ingest-plan: unknown frontmatter key %r (allowed: %s)" % (k, allowed_str), file=sys.stderr)
    sys.exit(1)

# Validate env
if "env" in data:
    env_val = data["env"]
    if env_val not in ("dev", "staging", "prod"):
        print("ingest-plan: invalid env value %r (must be dev, staging, or prod)" % env_val, file=sys.stderr)
        sys.exit(1)

# Validate auto_recommended
if "auto_recommended" in data:
    ar_val = data["auto_recommended"]
    if not isinstance(ar_val, bool):
        print("ingest-plan: invalid auto_recommended value %r (expected true|false)" % ar_val, file=sys.stderr)
        sys.exit(1)

# Validate aws block
if "aws" in data:
    aws = data["aws"]
    if not isinstance(aws, dict):
        print("ingest-plan: aws: must be a mapping", file=sys.stderr)
        sys.exit(1)
    required_aws_keys = {"account", "region", "profile", "cdk_app_path"}
    missing = required_aws_keys - set(aws.keys())
    if missing:
        missing_str = ", ".join(sorted(missing))
        print("ingest-plan: aws: block missing required sub-key(s): %s" % missing_str, file=sys.stderr)
        sys.exit(1)
    # Validate account format
    account = str(aws["account"])
    if not re.match(r"^[0-9]{12}$", account):
        print("ingest-plan: aws.account must be a 12-digit number, got: %r" % account, file=sys.stderr)
        sys.exit(1)
    # Normalize account to string
    data["aws"]["account"] = account
    # Validate non-empty strings
    for k in ("region", "profile", "cdk_app_path"):
        if not aws.get(k) or not str(aws[k]).strip():
            print("ingest-plan: aws.%s must be a non-empty string" % k, file=sys.stderr)
            sys.exit(1)

# Validate requires
if "requires" in data:
    reqs = data["requires"]
    if reqs is None:
        data["requires"] = []
    elif not isinstance(reqs, list):
        print("ingest-plan: requires: must be a list of PLAN-NN strings", file=sys.stderr)
        sys.exit(1)
    else:
        for entry in reqs:
            if not isinstance(entry, str) or not re.match(r"^PLAN-[0-9]{2}$", str(entry)):
                print("ingest-plan: requires: entry %r must match PLAN-NN format" % (entry,), file=sys.stderr)
                sys.exit(1)
        data["requires"] = [str(e) for e in reqs]

# Validate pre_flight
if "pre_flight" in data:
    pf = data["pre_flight"]
    if not isinstance(pf, dict):
        print("ingest-plan: pre_flight: must be a mapping", file=sys.stderr)
        sys.exit(1)
    if "issue_title" not in pf or not str(pf.get("issue_title", "")).strip():
        print("ingest-plan: pre_flight: issue_title is required and must be non-empty", file=sys.stderr)
        sys.exit(1)
    if "checklist" not in pf:
        print("ingest-plan: pre_flight: checklist is required", file=sys.stderr)
        sys.exit(1)
    checklist = pf["checklist"]
    if not isinstance(checklist, list) or len(checklist) == 0:
        print("ingest-plan: pre_flight: checklist must be a non-empty array", file=sys.stderr)
        sys.exit(1)
    for i, item in enumerate(checklist):
        if not isinstance(item, str) or not str(item).strip():
            print("ingest-plan: pre_flight: checklist[%d] must be a non-empty string" % i, file=sys.stderr)
            sys.exit(1)

print(json.dumps(data))
') || exit 1
fi

# Extract individual frontmatter fields from parsed JSON
AUTO_REC_JSON=$(echo "$FRONTMATTER_JSON" | jq -r 'if has("auto_recommended") then .auto_recommended else false end')
ENV_VAL=$(echo "$FRONTMATTER_JSON" | jq -r 'if has("env") then .env else "" end')
HAS_AWS=$(echo "$FRONTMATTER_JSON" | jq -r 'has("aws")')
HAS_REQUIRES=$(echo "$FRONTMATTER_JSON" | jq -r 'has("requires")')
HAS_PRE_FLIGHT=$(echo "$FRONTMATTER_JSON" | jq -r 'has("pre_flight")')

# ---- Pass 1: parse tasks ----
# Per-task gawk pass emits one JSON object per line with fields parsed
# from the task header. Validation happens in a second pass so we can
# report all problems at once.
TASKS_JSON=$("$GAWK" '
  function json_escape(s) {
    gsub(/\\/, "\\\\", s)
    gsub(/"/, "\\\"", s)
    gsub(/\t/, "\\t", s)
    gsub(/\r/, "\\r", s)
    return s
  }
  function emit_task() {
    if (current_task == "") return
    printf "{\"task\": %s, \"title\": \"%s\", \"depends_on\": [%s], \"touches\": [%s]",
      current_task, json_escape(title), depends_on, touches_json
    if (auto_merge_set) printf ", \"auto_merge\": %s", auto_merge_value
    if (max_turns_set) printf ", \"max_turns\": %s", max_turns_value
    printf ", \"deploy_mode\": \"%s\"", deploy_mode
    if (smoke_test_set) printf ", \"smoke_test\": \"%s\"", json_escape(smoke_test_value)
    printf "}\n"
  }
  BEGIN {
    in_fence = 0; current_task = ""; depends_on = ""; touches_json = ""
    auto_merge_set = 0; max_turns_set = 0
    deploy_mode = "operator"; smoke_test_set = 0; smoke_test_value = ""
    parse_errors = 0
  }
  /^```/ { in_fence = !in_fence; next }
  in_fence { next }
  /^## Task [0-9]+:/ {
    emit_task()
    match($0, /Task ([0-9]+):[[:space:]]*(.*)/, m)
    current_task = m[1]
    title = m[2]
    depends_on = ""
    touches_json = ""
    auto_merge_set = 0
    auto_merge_value = ""
    max_turns_set = 0
    max_turns_value = ""
    deploy_mode = "operator"
    smoke_test_set = 0
    smoke_test_value = ""
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
  current_task != "" && /^\*\*deploy_mode:\*\*/ {
    if (match($0, /\*\*deploy_mode:\*\*[[:space:]]*([a-zA-Z]+)/, dm) > 0) {
      val = dm[1]
      if (val == "operator" || val == "autonomous") {
        deploy_mode = val
      } else {
        printf "ingest-plan: task %s: deploy_mode value \"%s\" is invalid (must be operator or autonomous)\n",
          current_task, val > "/dev/stderr"
        parse_errors = 1
      }
    }
    next
  }
  current_task != "" && /^\*\*smoke_test:\*\*/ {
    line = $0
    sub(/^\*\*smoke_test:\*\*[[:space:]]*/, "", line)
    if (line ~ /\n/) {
      printf "ingest-plan: task %s: smoke_test must be a single line\n", current_task > "/dev/stderr"
      parse_errors = 1
    } else if (line != "") {
      smoke_test_set = 1
      smoke_test_value = line
    }
    next
  }
  END {
    emit_task()
    if (parse_errors) exit 1
  }
' "$PLAN") || exit 1

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

# ---- Cross-field validation: autonomous deploy_mode requires aws: block ----
AUTONOMOUS_TASKS=$(printf '%s\n' "$TASKS_JSON" | jq -r 'select(.deploy_mode == "autonomous") | .task')
if [ -n "$AUTONOMOUS_TASKS" ] && [ "$HAS_AWS" = "false" ]; then
  echo "ingest-plan: the following task(s) use deploy_mode: autonomous but no aws: frontmatter block is present:" >&2
  echo "$AUTONOMOUS_TASKS" | while read -r t; do echo "  task $t" >&2; done
  exit 1
fi

# ---- Cross-field validation: requires self-reference ----
if [ -n "$PLAN_SLUG" ] && [ "$HAS_REQUIRES" = "true" ]; then
  SELF_REF=$(echo "$FRONTMATTER_JSON" | jq -r --arg slug "$PLAN_SLUG" '.requires[] | select(. == $slug)')
  if [ -n "$SELF_REF" ]; then
    echo "ingest-plan: requires: contains self-reference ($PLAN_SLUG)" >&2
    exit 1
  fi
fi

# ---- Cross-field validation: requires referenced plans existence (warning only) ----
if [ "$HAS_REQUIRES" = "true" ]; then
  REPO_ROOT=$(git -C "$(dirname "$PLAN")" rev-parse --show-toplevel 2>/dev/null || true)
  while IFS= read -r req_plan; do
    [ -z "$req_plan" ] && continue
    FOUND=false
    if [ -n "$REPO_ROOT" ]; then
      if find "$REPO_ROOT/.claude/plans" -name "${req_plan}-*.md" -o -name "${req_plan}-*.state.json" 2>/dev/null | grep -q .; then
        FOUND=true
      fi
    fi
    if [ "$FOUND" = "false" ]; then
      echo "ingest-plan: warning: required plan $req_plan not found in .claude/plans/ (it may be created later)" >&2
    fi
  done < <(echo "$FRONTMATTER_JSON" | jq -r '.requires[]?')
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
      retries: 0,
      deploy_mode: ($t.deploy_mode // "operator")
    }
    + (if $t | has("max_turns") then {max_turns: $t.max_turns} else {} end)
    + (if ($t | has("smoke_test")) and ($t.smoke_test != null) then {smoke_test: $t.smoke_test} else {} end)
  ))
')

# Build optional top-level fields
ENV_FIELD=$([ -n "$ENV_VAL" ] && echo "\"$ENV_VAL\"" || echo "null")
AWS_ENV_FIELD=$([ "$HAS_AWS" = "true" ] && echo "$FRONTMATTER_JSON" | jq '.aws' || echo "null")
REQUIRES_FIELD=$([ "$HAS_REQUIRES" = "true" ] && echo "$FRONTMATTER_JSON" | jq '.requires' || echo "null")
PRE_FLIGHT_FIELD=$([ "$HAS_PRE_FLIGHT" = "true" ] && echo "$FRONTMATTER_JSON" | jq '.pre_flight' || echo "null")

jq -n \
  --argjson schema_version 3 \
  --arg plan_file "$PLAN" \
  --argjson total "$TOTAL" \
  --argjson tasks "$TASKS_OBJECT" \
  --argjson overrides "$OVERRIDES" \
  --argjson auto_rec "$AUTO_REC_JSON" \
  --argjson env_field "$ENV_FIELD" \
  --argjson aws_env "$AWS_ENV_FIELD" \
  --argjson requires "$REQUIRES_FIELD" \
  --argjson pre_flight "$PRE_FLIGHT_FIELD" \
  '{
    schema_version: $schema_version,
    plan_file: $plan_file,
    total_tasks: $total,
    status: "in_progress",
    tasks: $tasks,
    auto_merge_overrides: $overrides,
    auto_recommended: $auto_rec,
    ingested_at: (now | todateiso8601)
  }
  + (if $env_field != null then {env: $env_field} else {} end)
  + (if $aws_env != null then {aws_env: $aws_env} else {} end)
  + (if $requires != null then {requires: $requires} else {} end)
  + (if $pre_flight != null then {pre_flight: $pre_flight} else {} end)
  ' > "$STATE_FILE"

# ---- Summary ----
echo "Ingested: $PLAN"
echo "  Schema version:       3"
echo "  Tasks:                $TOTAL"
echo "  Auto-merge disabled:  $(echo "$OVERRIDES" | jq -r 'keys | join(", ") // "none"')"
echo "  Auto-recommended:     $AUTO_REC_JSON"
echo "  Env:                  ${ENV_VAL:-dev (default)}"
if [ "$HAS_AWS" = "true" ]; then
  echo "  AWS account:          $(echo "$FRONTMATTER_JSON" | jq -r '.aws.account')"
  echo "  AWS region:           $(echo "$FRONTMATTER_JSON" | jq -r '.aws.region')"
fi
if [ "$HAS_REQUIRES" = "true" ]; then
  echo "  Requires:             $(echo "$FRONTMATTER_JSON" | jq -r '.requires | join(", ")')"
fi
echo "  State file:           $STATE_FILE"
echo
echo "Review the state file, edit auto_merge_overrides if needed, then create issues:"
echo "  .claude/scripts/create-issues.sh $STATE_FILE"
