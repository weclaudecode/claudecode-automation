#!/usr/bin/env bash
# Emit up to N task numbers ready for launch.
#
# Usage: find-ready-tasks.sh <state_file> <max_tasks> [<owner/repo>]
#
# A task is "ready" iff:
#   - tasks.N.status == "pending"
#   - tasks.N.issue is set
#   - that issue has the `orch:deps-met` label on GitHub
#
# Output: up to <max_tasks> task numbers, one per line, in numerical
# order. Empty output is valid (nothing ready).
#
# Interim implementation. The Phase 4 version adds `touches:` collision
# detection — i.e., reject candidates whose globs overlap with any
# currently-in_review task. Until then, MAX_PARALLEL=1 is the safe
# default (no collision risk with a single worker).
#
# Optimization: one `gh issue list --label orch:task,orch:deps-met
# --state open` call returns ALL eligible issues; we intersect with the
# pending tasks in state.json. O(1) HTTP calls regardless of plan size.
#
# Exit codes:
#   0  output emitted (may be empty)
#   1  environment/args failure

set -uo pipefail

command -v jq >/dev/null || { echo "find-ready: jq required" >&2; exit 1; }
command -v gh >/dev/null || { echo "find-ready: gh required" >&2; exit 1; }

if [ $# -lt 2 ]; then
  echo "usage: $0 <state_file> <max_tasks> [<owner/repo>]" >&2
  exit 1
fi

STATE_FILE="$1"
MAX="$2"
REPO="${3:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"

[ -f "$STATE_FILE" ] || { echo "find-ready: state file not found: $STATE_FILE" >&2; exit 1; }
[[ "$MAX" =~ ^[0-9]+$ ]] || { echo "find-ready: max_tasks must be numeric, got '$MAX'" >&2; exit 1; }
[ -n "$REPO" ] || {
  echo "find-ready: no repo specified and gh auto-detect failed" >&2
  echo "  pass <owner/repo> as 3rd arg or run from a gh-tracked clone" >&2
  exit 1
}

# v2 schema check
jq -e '.tasks | type == "object"' "$STATE_FILE" >/dev/null 2>&1 || {
  echo "find-ready: state file lacks .tasks object (expected v2 schema): $STATE_FILE" >&2
  exit 1
}

# Zero slots → nothing to emit. Exit 0 silently.
[ "$MAX" -eq 0 ] && exit 0

# Build map: pending task_num -> issue_num. Filter out tasks with no
# linked issue (they can't have a label, so they can't be deps-met).
PENDING=$(jq -r '
  .tasks | to_entries[]
  | select(.value.status == "pending" and .value.issue != null)
  | "\(.key) \(.value.issue)"
' "$STATE_FILE")

if [ -z "$PENDING" ]; then
  exit 0
fi

# Single gh call: get all open deps-met-labeled task issues.
# --search lets us combine multiple label filters; AND is implicit.
DEPS_MET_ISSUES=$(gh issue list \
  --repo "$REPO" \
  --label "orch:task" \
  --label "orch:deps-met" \
  --state open \
  --json number \
  --limit 200 \
  --jq '[.[].number] | join(" ")' 2>/dev/null || echo "")

if [ -z "$DEPS_MET_ISSUES" ]; then
  exit 0
fi

# Intersect pending-tasks-with-issues against deps-met issues.
# Emit task numbers in numerical order, capped at MAX.
COUNT=0
while read -r task_num issue_num; do
  [ -z "$task_num" ] && continue
  [ "$COUNT" -ge "$MAX" ] && break
  # Word-boundary match against the deps-met issue list
  if echo " $DEPS_MET_ISSUES " | grep -q " $issue_num "; then
    echo "$task_num"
    COUNT=$((COUNT + 1))
  fi
done < <(printf '%s\n' "$PENDING" | sort -n -k1)

exit 0
