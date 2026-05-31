#!/usr/bin/env bash
# Dispatcher Phase 4: spawn iteration workers for PRs the reviewer has
# blocked since their last commit.
#
# Usage: iterate-pass.sh <state_file> [<owner/repo>]
#
# For each task in state.tasks.* with status == "in_review" and .pr set:
#   1. Fetch PR's body + headRefOid + state + labels in ONE gh call.
#   2. Skip if state != OPEN          -> sweep-merges owns the transition.
#   3. Skip if no orch:review-blocked -> nothing for the iterator to do.
#   4. Skip if orch:safety-block      -> escalated to a human; not for us.
#   5. Skip if review-sha marker != HEAD -> the label is stale; let
#      review-pass refresh it on the current commit first. Otherwise the
#      iterator would address findings the latest push already resolved.
#   6. Otherwise, spawn iterate-pr.sh in the background.
#
# Iterators run in parallel up to ORCH_MAX_PARALLEL (default 1). Cap is
# enforced with a poll loop (macOS bash 3.2 has no `wait -n`).
#
# Env vars:
#   ORCH_MAX_PARALLEL  default 1; cap on concurrent iterators.
#   ORCH_ITERATE_PR    test seam: path to the per-task runner (defaults
#                      to .claude/scripts/iterate-pr.sh under repo root).
#                      A path of "stub" makes this script log decisions
#                      without spawning anything — used in smoke tests.
#
# Exit codes:
#   0  pass complete (zero or more iterators spawned; all returned)
#   1  environment/args/state-file failure

set -uo pipefail

command -v jq >/dev/null || { echo "iterate-pass: jq required" >&2; exit 1; }
command -v gh >/dev/null || { echo "iterate-pass: gh required" >&2; exit 1; }

if [ $# -lt 1 ]; then
  echo "usage: $0 <state_file> [<owner/repo>]" >&2
  exit 1
fi

STATE_FILE="$1"
REPO="${2:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"

[ -f "$STATE_FILE" ] || { echo "iterate-pass: state file not found: $STATE_FILE" >&2; exit 1; }
[ -n "$REPO" ] || {
  echo "iterate-pass: no repo specified and gh auto-detect failed" >&2
  exit 1
}

# v2 schema check
jq -e '.tasks | type == "object"' "$STATE_FILE" >/dev/null 2>&1 || {
  echo "iterate-pass: state file lacks .tasks object (expected v2 schema)" >&2
  exit 1
}

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
ITERATOR="${ORCH_ITERATE_PR:-$REPO_ROOT/.claude/scripts/iterate-pr.sh}"
MAX_PARALLEL="${ORCH_MAX_PARALLEL:-1}"

if [ "$ITERATOR" != "stub" ]; then
  [ -x "$ITERATOR" ] || {
    echo "iterate-pass: iterator not executable at $ITERATOR" >&2
    exit 1
  }
fi
[[ "$MAX_PARALLEL" =~ ^[0-9]+$ ]] || {
  echo "iterate-pass: max_parallel must be numeric, got '$MAX_PARALLEL'" >&2
  exit 1
}

# Build candidate list: task_num pr_num
CANDIDATES=$(jq -r '
  .tasks | to_entries[]
  | select(.value.pr != null and .value.status == "in_review")
  | "\(.key) \(.value.pr)"
' "$STATE_FILE")

if [ -z "$CANDIDATES" ]; then
  echo "iterate-pass: no in_review tasks; nothing to iterate"
  exit 0
fi

LAUNCHED=0
SKIPPED_NO_LABEL=0
SKIPPED_SAFETY=0
SKIPPED_STALE_SHA=0
SKIPPED_NOT_OPEN=0
ITER_PIDS=()

# Poll-based slot cap. Wait until live PIDs count < MAX_PARALLEL.
wait_for_slot() {
  while true; do
    local alive=()
    for p in "${ITER_PIDS[@]+"${ITER_PIDS[@]}"}"; do
      if kill -0 "$p" 2>/dev/null; then
        alive+=("$p")
      fi
    done
    ITER_PIDS=("${alive[@]+"${alive[@]}"}")
    if [ "${#ITER_PIDS[@]}" -lt "$MAX_PARALLEL" ]; then
      return 0
    fi
    sleep 0.5
  done
}

while read -r task_num pr_num; do
  [ -z "$task_num" ] && continue

  # One gh call for body + sha + state + labels.
  PR_INFO=$(gh pr view "$pr_num" --repo "$REPO" --json body,headRefOid,state,labels 2>/dev/null || echo "")
  if [ -z "$PR_INFO" ]; then
    echo "iterate-pass: failed to fetch PR #$pr_num (task $task_num); skipping" >&2
    continue
  fi

  PR_STATE=$(echo "$PR_INFO" | jq -r '.state // "UNKNOWN"')
  if [ "$PR_STATE" != "OPEN" ]; then
    echo "iterate-pass: task $task_num PR #$pr_num is $PR_STATE — skip (sweep-merges owns)"
    SKIPPED_NOT_OPEN=$((SKIPPED_NOT_OPEN + 1))
    continue
  fi

  LABELS=$(echo "$PR_INFO" | jq -r '[.labels[].name] | join(",")')
  if ! echo ",$LABELS," | grep -q ',orch:review-blocked,'; then
    SKIPPED_NO_LABEL=$((SKIPPED_NO_LABEL + 1))
    continue
  fi

  if echo ",$LABELS," | grep -q ',orch:safety-block,'; then
    echo "iterate-pass: task $task_num PR #$pr_num has orch:safety-block — skip (human-only)"
    SKIPPED_SAFETY=$((SKIPPED_SAFETY + 1))
    continue
  fi

  HEAD_OID=$(echo "$PR_INFO" | jq -r '.headRefOid')
  PR_BODY=$(echo "$PR_INFO" | jq -r '.body // ""')
  # Require the full HTML-comment delimiters so a bare `orch:review-sha:HEX`
  # appearing inside PR-body prose or a fenced code block can't shadow the
  # real marker emitted by review-pr.sh / review-pass.sh. Stage 1 matches the
  # delimited form; stage 2 lifts the hex (7-40 chars: short refs through
  # full SHAs). Sibling of the review-pass.sh:154-161 fix (PR #72 / PLAN-08 T1).
  LAST_SHA=$(echo "$PR_BODY" \
    | grep -oE '<!-- *orch:review-sha:[a-f0-9]+ *-->' \
    | head -1 \
    | grep -oE '[a-f0-9]{7,40}')
  LAST_CI_GATE_SHA=$(echo "$PR_BODY" \
    | grep -oE '<!-- *orch:ci-gate-sha:[a-f0-9]+ *-->' \
    | head -1 \
    | grep -oE '[a-f0-9]{7,40}')

  # Either marker matching HEAD proves we have fresh feedback on the
  # current commit. review-sha = LLM review (review-pr.sh); ci-gate-sha =
  # synthetic CI-failure blocker (review-pass.sh Task 5.4 path). Without
  # checking both, the CI gate path is invisible to iterate-pass and the
  # loop deadlocks on a CI-only failure.
  FRESH_FEEDBACK=0
  [ -n "$LAST_SHA" ] && [ "$HEAD_OID" = "$LAST_SHA" ] && FRESH_FEEDBACK=1
  [ -n "$LAST_CI_GATE_SHA" ] && [ "$HEAD_OID" = "$LAST_CI_GATE_SHA" ] && FRESH_FEEDBACK=1

  if [ "$FRESH_FEEDBACK" -eq 0 ]; then
    # No marker matches HEAD → review-pass should re-evaluate against
    # current HEAD before we iterate. Otherwise we'd address findings the
    # latest push may have already resolved.
    LAST_DISPLAY="${LAST_SHA:-never}"
    CI_DISPLAY="${LAST_CI_GATE_SHA:-never}"
    echo "iterate-pass: task $task_num PR #$pr_num review-sha=${LAST_DISPLAY:0:8} ci-gate-sha=${CI_DISPLAY:0:8} both != head=${HEAD_OID:0:8} — skip (let review-pass refresh)"
    SKIPPED_STALE_SHA=$((SKIPPED_STALE_SHA + 1))
    continue
  fi

  wait_for_slot

  echo "iterate-pass: task $task_num PR #$pr_num head=${HEAD_OID:0:8} review-blocked -> iterating"
  if [ "$ITERATOR" = "stub" ]; then
    echo "iterate-pass: [stub] would spawn iterate-pr.sh $STATE_FILE $task_num"
    LAUNCHED=$((LAUNCHED + 1))
    continue
  fi

  bash "$ITERATOR" "$STATE_FILE" "$task_num" &
  ITER_PIDS+=("$!")
  LAUNCHED=$((LAUNCHED + 1))
done <<< "$CANDIDATES"

# Wait on every spawned iterator
for p in "${ITER_PIDS[@]+"${ITER_PIDS[@]}"}"; do
  wait "$p" 2>/dev/null || true
done

echo "iterate-pass: done — launched=$LAUNCHED no_label=$SKIPPED_NO_LABEL safety=$SKIPPED_SAFETY stale_sha=$SKIPPED_STALE_SHA not_open=$SKIPPED_NOT_OPEN"
exit 0
