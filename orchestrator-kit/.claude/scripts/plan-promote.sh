#!/usr/bin/env bash
# plan-promote.sh — Inter-plan ordering gate via the `requires` frontmatter field.
#
# Usage: plan-promote.sh <state-file>
#
# Exit codes:
#   0 — plan may be promoted to active (no unmet requires, or no requires at all)
#   1 — plan must wait (at least one required plan is not yet done but may
#       eventually finish — e.g. still in_progress or not yet created)
#   2 — hard error (malformed state file, bad arguments, jq not on PATH)
#   3 — permanently blocked: at least one required plan is archived as blocked
#       (no forward progress is possible without operator intervention)
#
# Called by orchestrator.sh during Phase 0 plan selection. For each candidate
# in_progress state file, the orchestrator calls this script. The first
# candidate that returns 0 becomes the active plan for the tick.
#
# Requires field in state JSON (schema v3):
#   { "requires": ["PLAN-03", "PLAN-04"], ... }
#
# Each required PLAN-NN must have status: done in its archived state file at
#   .claude/plans/archive/PLAN-NN-*.state.json
# before this plan is promoted.
#
# The script is always run from REPO root (same cwd as orchestrator.sh).

set -uo pipefail

STATE_FILE="${1:-}"
CURRENT_PLAN=$(basename "${STATE_FILE}" .state.json 2>/dev/null || echo "unknown")

if [ -z "$STATE_FILE" ]; then
  echo "plan-promote: usage: plan-promote.sh <state-file>" >&2
  exit 2
fi

if [ ! -f "$STATE_FILE" ]; then
  echo "plan-promote: state file not found: $STATE_FILE" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "plan-promote: jq not on PATH" >&2
  exit 2
fi

# ---- Step 1: read requires array; empty/missing → no deps, exit 0 ----
REQUIRES_JSON=$(jq -r '.requires // empty' "$STATE_FILE" 2>/dev/null)
if [ -z "$REQUIRES_JSON" ] || [ "$REQUIRES_JSON" = "null" ] || [ "$REQUIRES_JSON" = "[]" ]; then
  exit 0
fi

# Validate it's actually an array
REQUIRES_COUNT=$(echo "$REQUIRES_JSON" | jq -r 'if type == "array" then length else -1 end' 2>/dev/null || echo "-1")
if [ "$REQUIRES_COUNT" = "-1" ]; then
  echo "plan-promote: requires field is malformed (not an array) in $STATE_FILE" >&2
  exit 2
fi

if [ "$REQUIRES_COUNT" = "0" ]; then
  exit 0
fi

# ---- Step 2: check each required plan ----
ALL_MET=true
# Distinguish transient waits (exit 1) from permanent blocks (exit 3).
# A permanently-blocked required plan can never unblock this plan on its own —
# the operator must intervene. We track the two cases separately so the
# orchestrator can file an issue and mark the downstream plan blocked (exit 3)
# rather than spinning forever (exit 1).
ANY_PERMANENT_BLOCK=false

while IFS= read -r required_plan; do
  [ -z "$required_plan" ] && continue

  # Look for archived state file: .claude/plans/archive/PLAN-NN-*.state.json
  ARCHIVE_MATCH=$(find .claude/plans/archive -maxdepth 1 -name "${required_plan}-*.state.json" 2>/dev/null | head -1 || true)

  if [ -n "$ARCHIVE_MATCH" ]; then
    ARCHIVED_STATUS=$(jq -r '.status // empty' "$ARCHIVE_MATCH" 2>/dev/null)
    if [ "$ARCHIVED_STATUS" = "done" ]; then
      # Satisfied — this required plan is done
      continue
    elif [ "$ARCHIVED_STATUS" = "blocked" ]; then
      echo "plan-promote: $CURRENT_PLAN permanently blocked — required plan $required_plan is archived as blocked (operator intervention needed)" >&2
      ALL_MET=false
      ANY_PERMANENT_BLOCK=true
      continue
    else
      echo "plan-promote: $CURRENT_PLAN waiting on $required_plan (archived with unexpected status: ${ARCHIVED_STATUS:-unknown})" >&2
      ALL_MET=false
      continue
    fi
  fi

  # Not in archive — check active plans
  ACTIVE_MATCH=$(find .claude/plans -maxdepth 1 -name "${required_plan}-*.state.json" 2>/dev/null | head -1 || true)
  if [ -n "$ACTIVE_MATCH" ]; then
    ACTIVE_STATUS=$(jq -r '.status // empty' "$ACTIVE_MATCH" 2>/dev/null)
    echo "plan-promote: $CURRENT_PLAN waiting on $required_plan (still in_progress; status: ${ACTIVE_STATUS:-unknown})" >&2
    ALL_MET=false
  else
    echo "plan-promote: $CURRENT_PLAN waiting on $required_plan (not yet created)" >&2
    ALL_MET=false
  fi

done < <(echo "$REQUIRES_JSON" | jq -r '.[]' 2>/dev/null)

# ---- Step 3: result ----
if [ "$ALL_MET" = "true" ]; then
  exit 0
elif [ "$ANY_PERMANENT_BLOCK" = "true" ]; then
  # At least one required plan is permanently blocked — signal orchestrator.sh
  # to mark this plan blocked and file a GH issue. Do not spin.
  exit 3
else
  exit 1
fi
