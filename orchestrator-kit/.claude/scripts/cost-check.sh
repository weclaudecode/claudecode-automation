#!/usr/bin/env bash
# cost-check.sh — Pre-tick AWS cost ceiling check.
#
# Usage: cost-check.sh <state-file>
#
# Exit codes:
#   0 — within budget (or no aws_env block, or no budget configured)
#   1 — cost-block: projected month-end exceeds ORCH_COST_BUDGET_USD_PER_MONTH
#   2 — error: aws CLI missing, Cost Explorer API failure, bad args
#
# Called by orchestrator.sh after preflight-gate, before phase 1.
# Only queries Cost Explorer when the plan state has an aws_env block AND
# ORCH_COST_BUDGET_USD_PER_MONTH is set — each CE query costs ~$0.01.
#
# Cache: .claude/state/cost-check-cache.json (global, shared across plans).
# TTL: ORCH_COST_CACHE_TTL_S (default 600 seconds / 10 min).
#
# Projection assumption: simple linear extrapolation from month-to-date spend
# and days elapsed. No usage smoothing, no day-of-week adjustment. Weekends
# and seasonal patterns will cause the projection to over- or under-shoot;
# treat it as a rough early-warning guard, not an exact forecast.

set -uo pipefail

REPO=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO" || exit 2

STATE_FILE="${1:-}"
CACHE_FILE=".claude/state/cost-check-cache.json"
CACHE_TTL="${ORCH_COST_CACHE_TTL_S:-600}"

# ---- Argument + dependency validation ----
if [ -z "$STATE_FILE" ]; then
  echo "cost-check: usage: cost-check.sh <state-file>" >&2
  exit 2
fi

if [ ! -f "$STATE_FILE" ]; then
  echo "cost-check: state file not found: $STATE_FILE" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "cost-check: jq not on PATH" >&2
  exit 2
fi

# ---- Helper: file a deduped cost-block GitHub issue ----
# Reads globals: STATE_FILE, AWS_ACCOUNT, MONTH_TO_DATE_USD, PROJECTED_USD, BUDGET_USD
file_cost_block_issue() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "cost-check: gh CLI not available; skipping issue creation" >&2
    return 0
  fi

  local plan_base
  plan_base=$(basename "$STATE_FILE" .state.json)
  local issue_title="cost-block: ${plan_base} month projection"

  local existing
  existing=$(gh issue list \
    --search "$issue_title" \
    --state open \
    --limit 50 \
    --json number,title \
    2>/dev/null \
    | jq -r --arg t "$issue_title" '.[] | select(.title == $t) | .number' \
    | head -1)

  if [ -n "$existing" ]; then
    echo "cost-check: cost-block issue #${existing} already open, skipping creation" >&2
    return 0
  fi

  local body
  body="## AWS cost ceiling hit — orchestrator tick halted

**Plan:** \`${plan_base}\`
**Account:** \`${AWS_ACCOUNT}\`
**Month-to-date spend:** \$${MONTH_TO_DATE_USD}
**Projected month-end:** \$${PROJECTED_USD}
**Budget:** \$${BUDGET_USD} (via \`ORCH_COST_BUDGET_USD_PER_MONTH\`)

### Projection method
Simple linear extrapolation: \`(month-to-date / days-elapsed) × days-in-month\`.
No usage smoothing or day-of-week adjustment applied.

### What to do
- Review unexpected spend in the AWS Cost Explorer console for account \`${AWS_ACCOUNT}\`.
- To raise the ceiling: increase \`ORCH_COST_BUDGET_USD_PER_MONTH\` in the orchestrator environment.
- To disable enforcement: unset \`ORCH_COST_BUDGET_USD_PER_MONTH\`.
- To force-resume regardless: delete \`.claude/state/cost-check-cache.json\` and restart the tick.
- Close this issue once you have resolved the spend or adjusted the budget."

  local create_out
  create_out=$(gh issue create \
    --title "$issue_title" \
    --label "cost-block" \
    --body "$body" \
    2>&1) || true

  local new_num
  new_num=$(echo "$create_out" | grep -oE '[0-9]+$' | tail -1 || true)
  echo "cost-check: filed cost-block issue #${new_num:-?}: \"${issue_title}\"" >&2
}

# ---- Step 1: read aws_env from state ----
AWS_ACCOUNT=$(jq -r '.aws_env.account // empty' "$STATE_FILE" 2>/dev/null)
AWS_REGION=$(jq -r '.aws_env.region // empty' "$STATE_FILE" 2>/dev/null)

if [ -z "$AWS_ACCOUNT" ] || [ -z "$AWS_REGION" ]; then
  # No AWS context in this plan — nothing to check.
  exit 0
fi

# ---- Step 2: check budget env var ----
BUDGET_USD="${ORCH_COST_BUDGET_USD_PER_MONTH:-}"
if [ -z "$BUDGET_USD" ]; then
  # No budget configured — enforcement disabled.
  exit 0
fi

# ---- Step 3: check cache ----
# Cache is global (not per-state-file) because Cost Explorer is billed per
# call and one tick = one meaningful data point regardless of plan count.
NOW_EPOCH=$(date -u +%s)

if [ -f "$CACHE_FILE" ]; then
  CHECKED_AT_ISO=$(jq -r '.checked_at // empty' "$CACHE_FILE" 2>/dev/null)
  if [ -n "$CHECKED_AT_ISO" ]; then
    # Convert ISO8601 to epoch — GNU date first, python3 fallback for macOS.
    if CACHE_EPOCH=$(date -d "$CHECKED_AT_ISO" +%s 2>/dev/null); then
      : # GNU date (Linux)
    elif CACHE_EPOCH=$(python3 -c \
      "import datetime; dt=datetime.datetime.fromisoformat('${CHECKED_AT_ISO}'.replace('Z','+00:00')); print(int(dt.timestamp()))" \
      2>/dev/null); then
      : # python3 fallback
    else
      CACHE_EPOCH=0
    fi

    AGE=$(( NOW_EPOCH - CACHE_EPOCH ))
    if [ "$AGE" -lt "$CACHE_TTL" ]; then
      MONTH_TO_DATE_USD=$(jq -r '.month_to_date_usd' "$CACHE_FILE")
      PROJECTED_USD=$(jq -r '.projected_month_end_usd' "$CACHE_FILE")
      local_budget=$(jq -r '.budget_usd' "$CACHE_FILE")
      echo "cost-check: cache hit (age ${AGE}s), month-to-date \$${MONTH_TO_DATE_USD}, projected \$${PROJECTED_USD}, budget \$${local_budget}"

      if python3 -c \
        "import sys; sys.exit(0 if float('${PROJECTED_USD}') < float('${local_budget}') else 1)" \
        2>/dev/null; then
        echo "cost-check: OK (cached)"
        exit 0
      else
        echo "cost-check: BUDGET EXCEEDED (cached) — month-to-date \$${MONTH_TO_DATE_USD}, projected \$${PROJECTED_USD}, budget \$${local_budget}" >&2
        file_cost_block_issue
        exit 1
      fi
    fi
  fi
fi

# ---- Step 4: aws CLI check + Cost Explorer call ----
if ! command -v aws >/dev/null 2>&1; then
  echo "cost-check: aws CLI not on PATH — install per https://aws.amazon.com/cli/" >&2
  exit 2
fi

# Date helpers (portable: GNU date or macOS/BSD date + python3)
if date --version >/dev/null 2>&1; then
  # GNU date
  FIRST_OF_MONTH=$(date -u +%Y-%m-01)
  TOMORROW=$(date -u -d "tomorrow" +%Y-%m-%d)
  DAYS_IN_MONTH=$(date -u -d "$(date -u +%Y-%m-01) +1 month -1 day" +%d)
  DAY_OF_MONTH=$(date -u +%-d)
else
  # macOS / BSD date
  FIRST_OF_MONTH=$(date -u +%Y-%m-01)
  TOMORROW=$(date -u -v+1d +%Y-%m-%d)
  DAYS_IN_MONTH=$(python3 -c \
    "import calendar, datetime; t=datetime.date.today(); print(calendar.monthrange(t.year, t.month)[1])")
  DAY_OF_MONTH=$(date -u +%d | sed 's/^0//')
fi

CE_FILTER="{\"Dimensions\":{\"Key\":\"LINKED_ACCOUNT\",\"Values\":[\"${AWS_ACCOUNT}\"]}}"

CE_OUTPUT=$(AWS_DEFAULT_REGION="$AWS_REGION" aws ce get-cost-and-usage \
  --time-period "Start=${FIRST_OF_MONTH},End=${TOMORROW}" \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --filter "$CE_FILTER" \
  2>&1) || {
  echo "cost-check: aws ce get-cost-and-usage failed:" >&2
  echo "$CE_OUTPUT" >&2
  exit 2
}

MONTH_TO_DATE_USD=$(echo "$CE_OUTPUT" | jq -r \
  '.ResultsByTime[0].Total.UnblendedCost.Amount // empty' 2>/dev/null)

if [ -z "$MONTH_TO_DATE_USD" ] || [ "$MONTH_TO_DATE_USD" = "null" ]; then
  echo "cost-check: could not parse UnblendedCost from ce output" >&2
  echo "$CE_OUTPUT" >&2
  exit 2
fi

# ---- Step 5: linear projection ----
# projected = (mtd / days_elapsed) * days_in_month
# Use current day-of-month as days elapsed; clamp to 1 to avoid div-by-zero
# on the first day of the month when actual elapsed time may round to 0.
DAYS_ELAPSED=$(( DAY_OF_MONTH < 1 ? 1 : DAY_OF_MONTH ))

PROJECTED_USD=$(python3 -c "
mtd = float('${MONTH_TO_DATE_USD}')
elapsed = int('${DAYS_ELAPSED}')
total = int('${DAYS_IN_MONTH}')
projected = (mtd / elapsed) * total if elapsed > 0 else mtd
print('{:.2f}'.format(projected))
")

# ---- Write cache ----
mkdir -p "$(dirname "$CACHE_FILE")"
jq -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson mtd "$MONTH_TO_DATE_USD" \
  --arg budget "$BUDGET_USD" \
  --arg proj "$PROJECTED_USD" \
  '{checked_at: $ts, month_to_date_usd: $mtd, budget_usd: ($budget|tonumber), projected_month_end_usd: ($proj|tonumber)}' \
  > "$CACHE_FILE"

echo "cost-check: month-to-date \$${MONTH_TO_DATE_USD}, projected \$${PROJECTED_USD}, budget \$${BUDGET_USD}"

# ---- Step 6: decision ----
if python3 -c \
  "import sys; sys.exit(0 if float('${PROJECTED_USD}') < float('${BUDGET_USD}') else 1)" \
  2>/dev/null; then
  echo "cost-check: OK"
  exit 0
else
  echo "cost-check: BUDGET EXCEEDED — month-to-date \$${MONTH_TO_DATE_USD}, projected \$${PROJECTED_USD}, budget \$${BUDGET_USD}" >&2
  file_cost_block_issue
  exit 1
fi
