#!/usr/bin/env bash
# H5 heuristic: deadlock detector.
#
# Fires when orchestrator.log shows >= ORCH_MONITOR_H5_CONSECUTIVE_TICKS
# consecutive ticks ending in "launch-pass: no slots" with no MERGED events
# between them. Parses the last 20 tick blocks (=== tick ... === delimiters).
#
# Hash: H5-PLAN<NN>-RECENT
#
# Env:
#   STATE_FILE                         — path to plan state.json (set by monitor-sweep.sh)
#   LOG_FILE                           — path to orchestrator log
#                                        (default: .claude/state/orchestrator.log)
#   ORCH_MONITOR_H5_CONSECUTIVE_TICKS  — consecutive-tick threshold before firing (default 5)

set -uo pipefail

_H5_THRESHOLD="${ORCH_MONITOR_H5_CONSECUTIVE_TICKS:-5}"
_H5_LOG_FILE="${LOG_FILE:-.claude/state/orchestrator.log}"

if [ -f "$_H5_LOG_FILE" ]; then

  _h5_consecutive=$(python3 - "$_H5_LOG_FILE" <<'PYEOF' 2>/dev/null || echo "0"
import sys, re

with open(sys.argv[1]) as f:
    content = f.read()

# Split by tick headers, keeping the delimiter via capture group.
# Result: [pre, "=== tick ", body1, "=== tick ", body2, ...]
parts = re.split(r'^(=== tick )', content, flags=re.MULTILINE)

# Reconstruct each tick block: delimiter + body.
blocks = []
i = 1
while i + 1 < len(parts):
    blocks.append(parts[i] + parts[i + 1])
    i += 2

# Take the last 20 non-empty blocks.
blocks = [b for b in blocks if b.strip()][-20:]

# Count consecutive trailing ticks with "no slots" and no MERGED events.
count = 0
for block in reversed(blocks):
    if re.search(r'launch-pass: no slots', block) and not re.search(r'\bMERGED\b', block):
        count += 1
    else:
        break

print(count)
PYEOF
  )

  if [ "$_h5_consecutive" -ge "$_H5_THRESHOLD" ]; then
    _h5_plan_file=$(jq -r '.plan_file' "$STATE_FILE")
    _h5_pnum="${_h5_plan_file##*PLAN-}"
    _h5_pnum="${_h5_pnum%%-*}"
    _h5_pnum="${_h5_pnum:-00}"
    _h5_hash="H5-PLAN${_h5_pnum}-RECENT"

    _h5_in_review=$(jq -r \
      '.tasks | to_entries[] | select(.value.status == "in_review") | "  Task \(.key): PR #\(.value.pr // "?")"' \
      "$STATE_FILE")

    _h5_body="**Plan:** ${_h5_plan_file}
**Consecutive blocked ticks:** ${_h5_consecutive} (threshold: ${_H5_THRESHOLD})

The orchestrator has reported 'launch-pass: no slots' for the last
${_h5_consecutive} consecutive ticks with no tasks merging between them.
This suggests a deadlock where all parallel slots are held by stalled
in_review tasks.

**In-review tasks holding slots:**
${_h5_in_review:-  <none found>}

**To investigate:** review the PRs above for CI failures, merge conflicts,
or unexpected orch:needs-robbie labels. If a task is stuck awaiting human
review, either merge manually or clear the label to let auto-merge retry."

    monitor_finding "$_h5_hash" \
      "Plan ${_h5_pnum} deadlock: ${_h5_consecutive} consecutive ticks with no slots" \
      "$_h5_body"
  fi
fi
