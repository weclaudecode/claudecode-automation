#!/usr/bin/env bash
# preflight-gate.sh — Operator gate for plans with a pre_flight block.
#
# Usage: preflight-gate.sh <state-file>
#
# Exit codes:
#   0 — gate clear (no pre_flight block, or matching issue is closed)
#   1 — error (gh CLI missing, API error, malformed state, bad args)
#   2 — gate active (matching issue is open; tick should no-op)
#
# Called by orchestrator.sh after lock acquisition and active-plan selection,
# before phase 1 (refresh-deps). Runs once per tick, never loops.

set -uo pipefail

STATE_FILE="${1:-}"

if [ -z "$STATE_FILE" ]; then
  echo "preflight-gate: usage: preflight-gate.sh <state-file>" >&2
  exit 1
fi

if [ ! -f "$STATE_FILE" ]; then
  echo "preflight-gate: state file not found: $STATE_FILE" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "preflight-gate: jq not on PATH" >&2
  exit 1
fi

# -- Step 1: read pre_flight block; if absent, gate is clear --
# This check MUST come before the gh CLI guard so that plans without a
# pre_flight block short-circuit cleanly even when gh is not installed.
PRE_FLIGHT=$(jq -r '.pre_flight // empty' "$STATE_FILE" 2>/dev/null)
if [ -z "$PRE_FLIGHT" ]; then
  exit 0
fi

# Only need gh if we're going to file/check a preflight issue.
if ! command -v gh >/dev/null 2>&1; then
  echo "preflight-gate: gh CLI not on PATH" >&2
  exit 1
fi

ISSUE_TITLE=$(jq -r '.pre_flight.issue_title // empty' "$STATE_FILE" 2>/dev/null)
if [ -z "$ISSUE_TITLE" ]; then
  echo "preflight-gate: pre_flight.issue_title is missing or empty in $STATE_FILE" >&2
  exit 1
fi

PLAN_BASE=$(basename "$STATE_FILE" .state.json)

# -- Step 2: look for a matching issue (open or closed) --
# gh issue list --search is fuzzy, so we fetch both open and closed and
# match by exact title equality in jq.
OPEN_MATCH=$(gh issue list \
  --search "$ISSUE_TITLE" \
  --state open \
  --limit 200 \
  --json number,title \
  | jq -r --arg t "$ISSUE_TITLE" '.[] | select(.title == $t) | .number' \
  | head -1)

# -- Step 3: open issue found → gate active --
if [ -n "$OPEN_MATCH" ]; then
  echo "preflight: waiting on issue #${OPEN_MATCH}" >&2
  exit 2
fi

# -- Step 4: check for a closed issue with the same title --
CLOSED_MATCH=$(gh issue list \
  --search "$ISSUE_TITLE" \
  --state closed \
  --limit 200 \
  --json number,title \
  | jq -r --arg t "$ISSUE_TITLE" '.[] | select(.title == $t) | .number' \
  | head -1)

if [ -n "$CLOSED_MATCH" ]; then
  echo "preflight: cleared (issue #${CLOSED_MATCH} closed)" >&2
  exit 0
fi

# -- Step 5: no issue exists → create one, then gate active --
CHECKLIST=$(jq -r \
  '.pre_flight.checklist // [] | map("- [ ] " + .) | join("\n")' \
  "$STATE_FILE" 2>/dev/null)

BODY="Operator preflight checklist for ${PLAN_BASE}. Tick each box; close the issue when ready to unblock the orchestrator.

${CHECKLIST}"

CREATE_OUTPUT=$(gh issue create \
  --title "$ISSUE_TITLE" \
  --body "$BODY" \
  2>&1)
CREATE_EXIT=$?

if [ $CREATE_EXIT -ne 0 ]; then
  echo "preflight-gate: failed to create preflight issue (exit $CREATE_EXIT)" >&2
  while IFS= read -r line; do
    echo "  $line" >&2
  done <<< "$CREATE_OUTPUT"
  exit 1
fi

# Extract the issue number from the URL gh prints on success (e.g. https://.../issues/42)
NEW_NUM=$(echo "$CREATE_OUTPUT" | grep -oE '[0-9]+$' || true)
echo "preflight: created issue #${NEW_NUM:-?} \"${ISSUE_TITLE}\" — tick will wait until it is closed" >&2
exit 2
