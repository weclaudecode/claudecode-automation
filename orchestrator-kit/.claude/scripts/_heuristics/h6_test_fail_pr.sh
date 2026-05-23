#!/usr/bin/env bash
# H6 heuristic: test-fail PR detector.
#
# Fires when a worker's run file reports tests_result == "fail" but
# status == "complete" and the corresponding task in state.json has an open PR.
# This means the worker pushed code it knew had failing tests.
#
# Hash: H6-T${task_num}-R${retry}
# Body: PR link, plan, retry count, remediation suggestion.
#
# ── Stub-hook pattern for testing ─────────────────────────────────────────────
# If STATE_FILE contains ._test_run_fixtures (JSON array of run objects), the
# heuristic reads run data from that array instead of walking the filesystem.
# Shape:
#   ._test_run_fixtures = [
#     { "task": <num>, "retry": <num>, "status": "complete", "tests_result": "fail" },
#     ...
#   ]
# ──────────────────────────────────────────────────────────────────────────────
#
# Env:
#   STATE_FILE  — path to plan state.json (set by monitor-sweep.sh)
#   REPO        — owner/repo string (used only in issue body)
#   H6_RUN_DIR  — directory to search for run-plan*.json files in live mode
#                 (default: dirname of STATE_FILE)

set -uo pipefail

_h6_run_dir="${H6_RUN_DIR:-$(dirname "$STATE_FILE")}"

# Build a normalised JSON array of run objects: [{task, retry, status, tests_result}].
# In test mode, use the embedded fixture; in live mode, walk the filesystem.
if jq -e '._test_run_fixtures' "$STATE_FILE" >/dev/null 2>&1; then
  _h6_runs=$(jq -c '._test_run_fixtures' "$STATE_FILE")
else
  _h6_runs="["
  _h6_sep=""
  for _h6_file in "$_h6_run_dir"/run-plan*.json; do
    [ -f "$_h6_file" ] || continue

    _h6_outer_status=$(jq -r '.status // "unknown"' "$_h6_file" 2>/dev/null || echo "unknown")
    _h6_task_num=$(jq -r '.result | fromjson | .task // "0"' "$_h6_file" 2>/dev/null || echo "0")
    _h6_tests_result=$(jq -r '.result | fromjson | .tests_result // "unknown"' \
      "$_h6_file" 2>/dev/null || echo "unknown")

    # Derive retry from filename: run-plan-NN-tM-rR.json → last -rR segment.
    _h6_basename=$(basename "$_h6_file" .json)
    _h6_retry="${_h6_basename##*-r}"
    case "$_h6_retry" in
      ''|*[!0-9]*) _h6_retry=0 ;;
    esac

    _h6_entry=$(jq -cn \
      --arg task "$_h6_task_num" \
      --argjson retry "$_h6_retry" \
      --arg status "$_h6_outer_status" \
      --arg tests_result "$_h6_tests_result" \
      '{task: ($task | tonumber), retry: $retry, status: $status, tests_result: $tests_result}')
    _h6_runs="${_h6_runs}${_h6_sep}${_h6_entry}"
    _h6_sep=","
  done
  _h6_runs="${_h6_runs}]"
fi

while IFS= read -r _h6_run; do
  _h6_task_num=$(jq -r '.task' <<< "$_h6_run")
  _h6_retry=$(jq -r '.retry' <<< "$_h6_run")
  _h6_tests_result=$(jq -r '.tests_result' <<< "$_h6_run")
  _h6_status=$(jq -r '.status' <<< "$_h6_run")

  [ "$_h6_tests_result" = "fail" ] && [ "$_h6_status" = "complete" ] || continue

  _h6_pr=$(jq -r --arg n "$_h6_task_num" '.tasks[$n].pr // "null"' "$STATE_FILE")
  [ "$_h6_pr" != "null" ] && [ -n "$_h6_pr" ] || continue

  _h6_hash="H6-T${_h6_task_num}-R${_h6_retry}"
  _h6_plan_file=$(jq -r '.plan_file' "$STATE_FILE")
  _h6_pr_url="https://github.com/${REPO:-<repo>}/pull/${_h6_pr}"

  _h6_body="**PR:** ${_h6_pr_url}
**Task:** ${_h6_task_num}
**Plan:** ${_h6_plan_file}
**Retry:** ${_h6_retry}
**tests_result:** fail (worker status: complete)

The worker completed and opened a PR despite reporting failing tests.
This suggests the test runner is non-fatal, the worker ignored test failures,
or the plan's acceptance criteria do not require tests to pass.

**Fix:** Review PR #${_h6_pr} for test failures, fix them (or update the
plan's acceptance criteria if tests are intentionally skipped), then
re-trigger the review with \`SKIP_REVIEW=\` unset."

  monitor_finding "$_h6_hash" \
    "Task ${_h6_task_num} opened PR #${_h6_pr} with failing tests (retry ${_h6_retry})" \
    "$_h6_body"
done < <(jq -c '.[]' <<< "$_h6_runs")
