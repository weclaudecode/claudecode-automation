#!/usr/bin/env bash
# Refresh orch:deps-met labels on issues whose depends_on issues are now closed.
#
# Usage: refresh-deps.sh <state-file> [<owner/repo>]
#
# Run at the start of every orchestrator tick. For each open task issue
# without orch:deps-met, check whether all of its depends_on issues are
# closed; if so, add orch:deps-met.
#
# Dependency map is read from state.json, not from issue body parsing —
# the state file is the source of structured truth.

set -euo pipefail

command -v jq >/dev/null || { echo "refresh-deps: jq required" >&2; exit 1; }
command -v gh >/dev/null || { echo "refresh-deps: gh required" >&2; exit 1; }

if [ $# -lt 1 ]; then
  echo "usage: $0 <state-file> [<owner/repo>]" >&2
  exit 1
fi

STATE_FILE="$1"
REPO="${2:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"

[ -f "$STATE_FILE" ] || { echo "state file not found: $STATE_FILE" >&2; exit 1; }
[ -n "$REPO" ] || { echo "no repo specified and gh auto-detect failed" >&2; exit 1; }

TASK_NUMS=$(jq -r '.tasks | keys | .[]' "$STATE_FILE" | sort -n)
ADDED=0

for task_num in $TASK_NUMS; do
  ISSUE_NUM=$(jq -r ".tasks[\"$task_num\"].issue" "$STATE_FILE")
  if [ "$ISSUE_NUM" = "null" ] || [ -z "$ISSUE_NUM" ]; then
    continue
  fi

  # Skip if issue is closed (already done)
  STATE=$(gh issue view "$ISSUE_NUM" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
  [ "$STATE" != "OPEN" ] && continue

  # Skip if already has the label
  if gh issue view "$ISSUE_NUM" --repo "$REPO" --json labels -q '.labels[].name' 2>/dev/null \
       | grep -qFx "orch:deps-met"; then
    continue
  fi

  # Check all deps are closed
  DEPS=$(jq -r ".tasks[\"$task_num\"].depends_on | .[]?" "$STATE_FILE")
  ALL_CLOSED=true

  if [ -z "$DEPS" ]; then
    # No deps but no label? Add it.
    :
  else
    for dep in $DEPS; do
      DEP_ISSUE=$(jq -r ".tasks[\"$dep\"].issue" "$STATE_FILE")
      if [ "$DEP_ISSUE" = "null" ] || [ -z "$DEP_ISSUE" ]; then
        # Dep hasn't been issue-created yet; can't be deps-met
        ALL_CLOSED=false
        break
      fi
      DEP_STATE=$(gh issue view "$DEP_ISSUE" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
      if [ "$DEP_STATE" != "CLOSED" ]; then
        ALL_CLOSED=false
        break
      fi
    done
  fi

  if [ "$ALL_CLOSED" = "true" ]; then
    gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "orch:deps-met" >/dev/null
    echo "  task $task_num (#$ISSUE_NUM): deps satisfied → added orch:deps-met"
    ADDED=$((ADDED + 1))
  fi
done

echo "Done. Added orch:deps-met to $ADDED issue(s)."
