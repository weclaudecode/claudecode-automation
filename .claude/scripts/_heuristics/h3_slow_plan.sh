#!/usr/bin/env bash
# H3 heuristic: slow-plan detector.
#
# Fires when: plan.status == "in_progress", plan ingested
# >ORCH_MONITOR_H3_AGE_DAYS ago, AND fewer than
# ORCH_MONITOR_H3_MIN_MERGED_PCT% of tasks are merged.
#
# Hash: H3-PLAN<NN>
#
# Env:
#   STATE_FILE                      — path to plan state.json (set by monitor-sweep.sh)
#   ORCH_MONITOR_H3_AGE_DAYS        — threshold in days before firing (default 7)
#   ORCH_MONITOR_H3_MIN_MERGED_PCT  — merged % required to suppress firing (default 30)

set -uo pipefail

_H3_AGE_DAYS="${ORCH_MONITOR_H3_AGE_DAYS:-7}"
_H3_MIN_MERGED_PCT="${ORCH_MONITOR_H3_MIN_MERGED_PCT:-30}"

_h3_plan_status=$(jq -r '.status' "$STATE_FILE")
_h3_ingested_at=$(jq -r '.ingested_at' "$STATE_FILE")

if [ "$_h3_plan_status" = "in_progress" ] && \
   [ -n "$_h3_ingested_at" ] && [ "$_h3_ingested_at" != "null" ]; then

  _h3_elapsed_days=$(python3 - "$_h3_ingested_at" <<'PYEOF' 2>/dev/null || echo "0"
from datetime import datetime, timezone
import sys
ingested_at = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
now = datetime.now(timezone.utc)
print(int((now - ingested_at).total_seconds() / 86400))
PYEOF
  )

  _h3_total=$(jq -r '.total_tasks' "$STATE_FILE")
  _h3_merged=$(jq -r '[.tasks[] | select(.status == "merged")] | length' "$STATE_FILE")

  _h3_merged_pct=$(python3 - "$_h3_merged" "$_h3_total" <<'PYEOF' 2>/dev/null || echo "100"
import sys
merged = int(sys.argv[1])
total = int(sys.argv[2])
print(0 if total == 0 else int(merged * 100 / total))
PYEOF
  )

  if [ "$_h3_elapsed_days" -gt "$_H3_AGE_DAYS" ] && [ "$_h3_merged_pct" -lt "$_H3_MIN_MERGED_PCT" ]; then
    _h3_plan_file=$(jq -r '.plan_file' "$STATE_FILE")
    _h3_pnum="${_h3_plan_file##*PLAN-}"
    _h3_pnum="${_h3_pnum%%-*}"
    _h3_pnum="${_h3_pnum:-00}"
    _h3_hash="H3-PLAN${_h3_pnum}"

    _h3_body="**Plan:** ${_h3_plan_file}
**Ingested:** ${_h3_ingested_at}
**Elapsed:** ${_h3_elapsed_days} days (threshold: ${_H3_AGE_DAYS} days)
**Progress:** ${_h3_merged}/${_h3_total} tasks merged (below ${_H3_MIN_MERGED_PCT}% threshold)

This plan has been in_progress for over ${_H3_AGE_DAYS} days but fewer than
${_H3_MIN_MERGED_PCT}% of tasks have merged, suggesting the pipeline may be stalled.

**To investigate:** check individual blocked tasks in the dashboard issue,
look for cascaded blocks (upstream_blocked_tN), or review in_review tasks
that may be stuck awaiting review."

    monitor_finding "$_h3_hash" \
      "Plan ${_h3_pnum} slow: ${_h3_merged}/${_h3_total} merged after ${_h3_elapsed_days} days" \
      "$_h3_body"
  fi
fi
