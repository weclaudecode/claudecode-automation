#!/usr/bin/env bash
# Monitor sweep — Phase 7 heuristic health check.
#
# Usage: monitor-sweep.sh <state_file> [<owner/repo>]
#
# Sources every .sh file in .claude/scripts/_heuristics/ in glob order.
# Each heuristic reads $STATE_FILE and $REPO from the environment and calls
# monitor_finding when a pattern fires. Findings are hash-dedup'd via a gh
# issue search before a new issue is created.
#
# Test mode: set MONITOR_TEST_MODE=1 before sourcing or running. monitor_finding
# will append each fired hash to MONITOR_FINDINGS_OBSERVED (caller must declare
# that array) and return without touching gh.
#
# Exit codes:
#   0  sweep complete (check output for per-finding details)
#   1  environment/args failure

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

# shellcheck source=_dispatcher_lib.sh
source "$REPO_ROOT/.claude/scripts/_dispatcher_lib.sh"

# Running totals — incremented inside monitor_finding.
MONITOR_FINDINGS=0
MONITOR_DEDUPED=0
MONITOR_FIRED=0

# monitor_finding <hash> <title> <body>
#
# The hash is a short deterministic string that uniquely identifies the class
# of problem (e.g. "h1-stall-t3"). It appears in the issue title so the gh
# search-based dedup can find it across retries.
#
# In MONITOR_TEST_MODE=1 the function appends hash to MONITOR_FINDINGS_OBSERVED
# without calling gh. Callers must declare that array before sourcing/running.
monitor_finding() {
  local hash="$1" title="$2" body="$3"
  MONITOR_FINDINGS=$((MONITOR_FINDINGS + 1))

  if [ "${MONITOR_TEST_MODE:-0}" = "1" ]; then
    MONITOR_FINDINGS_OBSERVED+=("$hash")
    MONITOR_FIRED=$((MONITOR_FIRED + 1))
    return 0
  fi

  local count
  count=$(gh issue list \
    --repo "$REPO" \
    --label "monitor:finding" \
    --state open \
    --search "$hash" \
    --json number \
    --jq 'length' 2>/dev/null || echo "0")

  if [ "$count" -ge 1 ]; then
    echo "monitor: dedup hit for $hash"
    MONITOR_DEDUPED=$((MONITOR_DEDUPED + 1))
    return 0
  fi

  local url
  url=$(gh issue create \
    --repo "$REPO" \
    --label "monitor:finding" \
    --title "$title" \
    --body "$body" 2>/dev/null || echo "")

  if [ -n "$url" ]; then
    echo "$url"
    MONITOR_FIRED=$((MONITOR_FIRED + 1))
  else
    echo "monitor: warning — gh issue create failed for $hash" >&2
  fi
}

# setup_monitor_label
#
# Ensures the monitor:finding label exists in the repo. Uses --force so it
# is idempotent (update color/description if the label already exists).
# Best-effort: failure is logged but never aborts the sweep.
setup_monitor_label() {
  gh label create "monitor:finding" \
    --color "e4e669" \
    --description "Auto-filed by monitor-sweep.sh" \
    --force \
    --repo "$REPO" >/dev/null 2>&1 \
    || echo "monitor: warning — could not ensure monitor:finding label (continuing)" >&2
}

# Main body — skipped when this file is sourced (e.g. by the test harness).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Belt-and-braces: the orchestrator already checks ORCH_MONITOR_ENABLED before
  # invoking this script, but guard here too so direct invocations respect the flag.
  if [ "${ORCH_MONITOR_ENABLED:-1}" != "1" ]; then
    echo "monitor-sweep: disabled via ORCH_MONITOR_ENABLED=0, exiting"
    exit 0
  fi

  if [ $# -lt 1 ]; then
    echo "usage: $0 <state_file> [<owner/repo>]" >&2
    exit 1
  fi

  STATE_FILE="$1"
  REPO="${2:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"

  [ -f "$STATE_FILE" ] || { echo "monitor-sweep: state file not found: $STATE_FILE" >&2; exit 1; }
  [ -n "$REPO" ] || {
    echo "monitor-sweep: no repo specified and gh auto-detect failed" >&2
    exit 1
  }

  setup_monitor_label

  HEURISTICS_DIR="$REPO_ROOT/.claude/scripts/_heuristics"
  for heuristic in "$HEURISTICS_DIR"/*.sh; do
    [ -f "$heuristic" ] || continue
    # shellcheck disable=SC1090
    source "$heuristic"
  done

  echo "monitor-sweep: done — findings=$MONITOR_FINDINGS, deduped=$MONITOR_DEDUPED, fired=$MONITOR_FIRED"
fi
