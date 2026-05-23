#!/usr/bin/env bash
# H1 heuristic: stuck orch:needs-robbie PR detector.
#
# Fires when a task is in_review with label orch:needs-robbie for longer than
# ORCH_MONITOR_H1_AGE_HOURS hours (default 24) and the task is NOT in
# auto_merge_overrides (which makes the label intentional — a human-review gate).
#
# This detects the exact bug that stalled propscan-au for 16 hours:
#   https://github.com/weclaudecode/claudecode-automation/issues/1
# A task got orch:needs-robbie but was not flagged as a sensitive task, so
# no human was assigned and the orchestrator loop silently did nothing.
#
# ── Stub-hook pattern for testing ─────────────────────────────────────────────
# If STATE_FILE contains ._test_pr_fixtures (a JSON object keyed by PR number),
# the heuristic reads PR data from that field instead of calling `gh pr view`.
# This allows offline test execution without network access or a real repo.
# Shape:
#   ._test_pr_fixtures["<pr_number>"] = {
#     "labels":    [{"name": "orch:needs-robbie"}, ...],
#     "createdAt": "<iso8601>",
#     "updatedAt": "<iso8601>"
#   }
# Future heuristics that call gh should use this same pattern.
# ──────────────────────────────────────────────────────────────────────────────
#
# Env:
#   STATE_FILE                 — path to plan state.json (set by monitor-sweep.sh)
#   REPO                       — owner/repo string (not needed in test mode)
#   ORCH_MONITOR_H1_AGE_HOURS  — threshold in hours before firing (default 24)

set -uo pipefail

_H1_THRESHOLD="${ORCH_MONITOR_H1_AGE_HOURS:-24}"

while IFS= read -r _h1_entry; do
  _h1_task_num=$(jq -r '.key' <<< "$_h1_entry")
  _h1_pr=$(jq -r '.value.pr' <<< "$_h1_entry")

  # Skip if task is in auto_merge_overrides — orch:needs-robbie is intentional there.
  _h1_override=$(jq -r --arg n "$_h1_task_num" '.auto_merge_overrides[$n] // "missing"' "$STATE_FILE")
  [ "$_h1_override" != "false" ] || continue

  # Resolve PR data — use _test_pr_fixtures when present (offline test stub).
  if jq -e '._test_pr_fixtures' "$STATE_FILE" >/dev/null 2>&1; then
    _h1_pr_json=$(jq -c --arg pr "$_h1_pr" '._test_pr_fixtures[$pr]' "$STATE_FILE")
  else
    _h1_pr_json=$(gh pr view "$_h1_pr" --repo "${REPO}" \
      --json labels,createdAt,updatedAt 2>/dev/null || true)
  fi
  [ -n "$_h1_pr_json" ] && [ "$_h1_pr_json" != "null" ] || continue

  # Fire only if orch:needs-robbie is present.
  _h1_has_label=$(jq -r \
    'if .labels | map(.name) | any(. == "orch:needs-robbie") then "1" else "0" end' \
    <<< "$_h1_pr_json")
  [ "$_h1_has_label" = "1" ] || continue

  # Compute hours since updatedAt.
  _h1_updated_at=$(jq -r '.updatedAt' <<< "$_h1_pr_json")
  _h1_age_hours=$(python3 - "$_h1_updated_at" <<'PYEOF' 2>/dev/null || echo "0"
from datetime import datetime, timezone
import sys
updated = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
now = datetime.now(timezone.utc)
print(int((now - updated).total_seconds() / 3600))
PYEOF
)

  if [ "$_h1_age_hours" -ge "$_H1_THRESHOLD" ]; then
    _h1_plan_file=$(jq -r '.plan_file' "$STATE_FILE")
    _h1_pr_url="https://github.com/${REPO:-<repo>}/pull/${_h1_pr}"
    _h1_body="**PR:** ${_h1_pr_url}
**Task:** ${_h1_task_num}
**Plan:** ${_h1_plan_file}
**Hours stuck:** ${_h1_age_hours}h (threshold: ${_H1_THRESHOLD}h)

This matches the stall class documented at:
https://github.com/weclaudecode/claudecode-automation/issues/1

A task received orch:needs-robbie but was not listed in auto_merge_overrides,
so the orchestrator loop had no human assignee and did nothing.

**Fix:** Merge the PR manually, OR add task ${_h1_task_num} to
auto_merge_overrides if the human-review gate was intentional."

    monitor_finding "H1-PR${_h1_pr}" \
      "PR #${_h1_pr} stuck in orch:needs-robbie for >${_H1_THRESHOLD}h" \
      "$_h1_body"
  fi
done < <(jq -c \
  '.tasks | to_entries[] | select(.value.status == "in_review" and .value.pr != null)' \
  "$STATE_FILE")
