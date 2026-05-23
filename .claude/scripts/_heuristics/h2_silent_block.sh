#!/usr/bin/env bash
# H2 heuristic: silent worker-failed-3x detector.
#
# Fires when a task reached blocked_reason: worker_failed_3x but has zero
# entries in decisions.md during the 24-hour window before blocked_at.
# This typically means the worker failed at claude -p startup — before any
# decision-making could occur — leaving the operator with no audit trail.
#
# Pattern: .status == "blocked" AND .blocked_reason == "worker_failed_3x"
# AND decisions.md has no ## YYYY-MM-DD HH:MM headers in [blocked_at-24h, blocked_at].
#
# Env:
#   STATE_FILE      — path to plan state.json (set by monitor-sweep.sh)
#   DECISIONS_FILE  — path to decisions.md (default: .claude/state/decisions.md)

set -uo pipefail

_H2_DECISIONS_FILE="${DECISIONS_FILE:-.claude/state/decisions.md}"

while IFS= read -r _h2_entry; do
  _h2_task_num=$(jq -r '.key' <<< "$_h2_entry")
  _h2_blocked_at=$(jq -r '.value.blocked_at' <<< "$_h2_entry")

  [ -n "$_h2_blocked_at" ] && [ "$_h2_blocked_at" != "null" ] || continue

  # Count decisions.md headers in [blocked_at - 24h, blocked_at].
  _h2_decision_count=$(python3 - "$_h2_blocked_at" "$_H2_DECISIONS_FILE" <<'PYEOF' 2>/dev/null || echo "0"
from datetime import datetime, timezone, timedelta
import sys, re

blocked_at = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
window_start = blocked_at - timedelta(hours=24)
count = 0
try:
    with open(sys.argv[2]) as f:
        for line in f:
            m = re.match(r'^## (\d{4}-\d{2}-\d{2} \d{2}:\d{2})', line)
            if m:
                ts = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M").replace(tzinfo=timezone.utc)
                if window_start <= ts <= blocked_at:
                    count += 1
except FileNotFoundError:
    pass
print(count)
PYEOF
)

  if [ "$_h2_decision_count" -eq 0 ]; then
    _h2_plan_file=$(jq -r '.plan_file' "$STATE_FILE")
    _h2_pnum="${_h2_plan_file##*PLAN-}"
    _h2_pnum="${_h2_pnum%%-*}"
    _h2_pnum="${_h2_pnum:-00}"
    _h2_state_dir="$(dirname "$STATE_FILE")"
    _h2_hash="H2-PLAN${_h2_pnum}-T${_h2_task_num}"

    _h2_body="**Task:** ${_h2_task_num}
**Plan:** ${_h2_plan_file}
**Blocked at:** ${_h2_blocked_at}
**Decisions in 24h window:** 0

The worker failed 3 times and was auto-blocked, but left no entries in
decisions.md in the 24 hours before blocking. This typically means the
worker failed at \`claude -p\` startup — before any decision-making ran.

**To diagnose:** inspect worker logs in \`${_h2_state_dir}/\` for the
task's worker invocation (look for run-*.json or similar output files
near the blocked timestamp).

**To fix:** resolve the startup issue (quota, auth, prompt error), then
reset task ${_h2_task_num} status to \`pending\` to retry."

    monitor_finding "$_h2_hash" \
      "Task ${_h2_task_num} silently failed 3× — no decisions logged (plan ${_h2_pnum})" \
      "$_h2_body"
  fi
done < <(jq -c \
  '.tasks | to_entries[] | select(.value.status == "blocked" and .value.blocked_reason == "worker_failed_3x")' \
  "$STATE_FILE")
