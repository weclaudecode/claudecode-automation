#!/usr/bin/env bash
# Watch CI on main for a merged PR's commit; notify on red (Task 5.2).
# Optionally run a per-task smoke test after CI goes green (Task 9).
#
# Usage: post-merge-check.sh <pr_num> [<owner/repo> [<state_file> <task_num>]]
#
# When <state_file> and <task_num> are supplied the script reads
# state.tasks.<task_num>.smoke_test; if the field is non-empty the command
# is executed (with a timeout) after CI turns green, and the result
# is reflected via PR labels, a comment, and — on failure — a blocker
# GitHub issue + cascade_block of downstream pending tasks.
#
# Designed to be launched in the background by sweep-merges.sh
# immediately after a MERGED state transition. It does NOT auto-revert
# — humans decide whether to roll back. Output goes to
# .claude/state/post-merge.log via the orchestrator's redirected fds.
#
# Polling model:
#   1. Fetch mergeCommit.oid from the PR.
#   2. Wait up to ORCH_POST_MERGE_GRACE for any workflow run to register
#      against that SHA (CI may take a few seconds to enqueue).
#   3. Poll all runs for that SHA on a fixed interval. When every run
#      reaches `completed`, evaluate conclusions.
#   4. Any non-success conclusion -> notify with a `git revert` command.
#   5. If smoke_test is set, run it (bounded by ORCH_SMOKE_TIMEOUT_S).
#
# Knobs:
#   ORCH_POST_MERGE_TIMEOUT   total seconds before giving up   (default 1800 = 30 min)
#   ORCH_POST_MERGE_GRACE     seconds to wait for runs to register (default 60)
#   ORCH_POST_MERGE_POLL      seconds between polls            (default 30)
#   ORCH_SMOKE_TIMEOUT_S      max seconds for smoke_test command (default 300 = 5 min)
#
# Exit codes (informational only — caller backgrounded us):
#   0  CI green (+ smoke ok if configured) OR no CI registered within grace OR timeout
#   1  environment/args failure
#   2  CI red (notification was sent)
#   3  smoke test failed or timed out

set -uo pipefail

command -v jq >/dev/null || { echo "post-merge-check: jq required" >&2; exit 1; }
command -v gh >/dev/null || { echo "post-merge-check: gh required" >&2; exit 1; }

if [ $# -lt 1 ]; then
  echo "usage: $0 <pr_num> [<owner/repo> [<state_file> <task_num>]]" >&2
  exit 1
fi

PR_NUM="$1"
REPO="${2:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
STATE_FILE="${3:-}"
TASK_NUM="${4:-}"

[[ "$PR_NUM" =~ ^[0-9]+$ ]] || { echo "post-merge-check: PR num must be numeric, got '$PR_NUM'" >&2; exit 1; }
[ -n "$REPO" ] || { echo "post-merge-check: no repo and gh autodetect failed" >&2; exit 1; }

TIMEOUT="${ORCH_POST_MERGE_TIMEOUT:-1800}"
GRACE="${ORCH_POST_MERGE_GRACE:-60}"
POLL="${ORCH_POST_MERGE_POLL:-30}"
SMOKE_TIMEOUT="${ORCH_SMOKE_TIMEOUT_S:-300}"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
NOTIFY="$REPO_ROOT/.claude/scripts/notify.sh"

# Source dispatcher lib if a state file was provided (needed for
# cascade_block and state_write). Best-effort: if missing, smoke-test
# cascade is skipped with a warning rather than aborting the CI watch.
_LIB_LOADED=0
if [ -n "$STATE_FILE" ]; then
  _DISPATCHER_LIB="$REPO_ROOT/.claude/scripts/_dispatcher_lib.sh"
  if [ -f "$_DISPATCHER_LIB" ]; then
    # shellcheck source=_dispatcher_lib.sh
    source "$_DISPATCHER_LIB"
    _LIB_LOADED=1
  else
    echo "post-merge-check: warning — _dispatcher_lib.sh not found; smoke cascade_block disabled" >&2
  fi
fi

# ---- ensure_label <label> <color> <description> ----
# Create the label if it doesn't already exist on the repo.
# Inline because setup-labels.sh is outside our touches constraint
# (spec §"Label setup" — idempotent inline creation).
ensure_label() {
  local label="$1" color="$2" desc="$3"
  if ! gh label list --repo "$REPO" --limit 100 --json name \
       2>/dev/null | jq -e --arg l "$label" '.[] | select(.name == $l)' >/dev/null 2>&1; then
    gh label create "$label" --color "$color" --description "$desc" \
      --repo "$REPO" --force >/dev/null 2>&1 || true
  fi
}

# ---- run_smoke_test <pr_num> <task_num> <smoke_cmd> ----
# Execute the smoke command and handle pass / fail / timeout.
run_smoke_test() {
  local pr="$1" task="$2" smoke_cmd="$3"

  echo "smoke-test: task $task starting (timeout ${SMOKE_TIMEOUT}s): $smoke_cmd"

  # Locate a timeout binary (coreutils timeout or gtimeout on macOS).
  local timeout_bin
  timeout_bin=$(command -v timeout 2>/dev/null \
    || command -v gtimeout 2>/dev/null \
    || true)

  local smoke_out smoke_rc=0
  if [ -n "$timeout_bin" ]; then
    smoke_out=$("$timeout_bin" "$SMOKE_TIMEOUT" bash -c "$smoke_cmd" 2>&1) || smoke_rc=$?
  else
    # No timeout binary — run without ceiling (warn so operator knows).
    echo "smoke-test: warning — no timeout binary found; smoke_test runs unbounded" >&2
    smoke_out=$(bash -c "$smoke_cmd" 2>&1) || smoke_rc=$?
  fi

  # timeout(1) exits 124 on expiry.
  local failure_reason="smoke_failed"
  if [ "$smoke_rc" -eq 124 ]; then
    failure_reason="smoke_timed_out"
    echo "smoke-test: task $task TIMED OUT after ${SMOKE_TIMEOUT}s"
  elif [ "$smoke_rc" -eq 0 ]; then
    echo "smoke-test: task $task OK (exit 0)"
    ensure_label "orch:smoke-ok" "0e8a16" "Post-deploy smoke test passed"
    gh pr edit "$pr" --repo "$REPO" --add-label "orch:smoke-ok" >/dev/null 2>&1 \
      || echo "smoke-test: warning — failed to add orch:smoke-ok label to PR #$pr" >&2
    return 0
  else
    echo "smoke-test: task $task FAILED (exit $smoke_rc)"
  fi

  # --- Failure path (non-zero or timeout) ---
  ensure_label "orch:smoke-failed" "b60205" "Post-deploy smoke test failed or timed out"
  gh pr edit "$pr" --repo "$REPO" --add-label "orch:smoke-failed" >/dev/null 2>&1 \
    || echo "smoke-test: warning — failed to add orch:smoke-failed label to PR #$pr" >&2

  # Truncate output to last 50 lines for the PR comment body.
  local truncated_out
  truncated_out=$(echo "$smoke_out" | tail -50)

  gh pr comment "$pr" --repo "$REPO" --body "$(printf \
    '**smoke-test FAILED** (task %s, exit %s, reason: %s)\n\n**Command:** `%s`\n\n**Output (last 50 lines):**\n```\n%s\n```\n\nInvestigate and re-run or unblock dependents manually.' \
    "$task" "$smoke_rc" "$failure_reason" "$smoke_cmd" "$truncated_out")" \
    >/dev/null 2>&1 \
    || echo "smoke-test: warning — failed to post failure comment on PR #$pr" >&2

  # File a blocker issue — idempotent: search for existing title first.
  local issue_title="smoke-failed: task $task (PR #$pr)"
  local existing_issue
  existing_issue=$(gh issue list --repo "$REPO" --state open \
    --search "\"$issue_title\" in:title" --json number -q '.[0].number' \
    2>/dev/null || true)

  if [ -z "$existing_issue" ]; then
    gh issue create --repo "$REPO" \
      --title "$issue_title" \
      --body "$(printf \
        '## Smoke-test failure\n\n- **Task:** %s\n- **PR:** #%s\n- **Exit code:** %s\n- **Reason:** %s\n- **Command:** `%s`\n\n## Output (last 50 lines)\n```\n%s\n```\n\n## Suggested actions\n1. Inspect the deployed resources in the target environment.\n2. Re-run the smoke command manually: `%s`\n3. If the environment needs remediation, fix it and close this issue.\n4. To unblock dependent tasks, operator must manually set their status in the plan state file or re-run the failing task.' \
        "$task" "$pr" "$smoke_rc" "$failure_reason" "$smoke_cmd" "$truncated_out" "$smoke_cmd")" \
      --label "orch:smoke-failed" \
      >/dev/null 2>&1 \
      || echo "smoke-test: warning — failed to create blocker issue for task $task" >&2
  else
    echo "smoke-test: blocker issue already exists (#$existing_issue); skipping creation"
  fi

  # Cascade-block downstream pending tasks if the dispatcher lib loaded.
  if [ "$_LIB_LOADED" -eq 1 ] && [ -f "${STATE_FILE:-}" ]; then
    cascade_block "$STATE_FILE" "$task" \
      || echo "smoke-test: warning — cascade_block returned non-zero for task $task" >&2
  else
    echo "smoke-test: skipping cascade_block (no state file or lib not loaded)" >&2
  fi

  return 1
}

MERGE_SHA=$(gh pr view "$PR_NUM" --repo "$REPO" --json mergeCommit -q .mergeCommit.oid 2>/dev/null)
if [ -z "$MERGE_SHA" ] || [ "$MERGE_SHA" = "null" ]; then
  echo "post-merge-check: PR #$PR_NUM has no merge commit (not merged?); exiting"
  exit 0
fi
SHORT_SHA="${MERGE_SHA:0:8}"
echo "post-merge-check: watching CI on $SHORT_SHA (PR #$PR_NUM) timeout=${TIMEOUT}s"

# Phase 1: wait for runs to register (CI may be slow to enqueue).
elapsed=0
RUNS_JSON=""
while [ "$elapsed" -lt "$GRACE" ]; do
  RUNS_JSON=$(gh api "repos/$REPO/actions/runs?head_sha=$MERGE_SHA" --jq '.workflow_runs // []' 2>/dev/null || echo "[]")
  COUNT=$(echo "$RUNS_JSON" | jq 'length')
  if [ "${COUNT:-0}" -gt 0 ]; then
    echo "post-merge-check: $COUNT run(s) registered for $SHORT_SHA after ${elapsed}s"
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

COUNT=$(echo "$RUNS_JSON" | jq 'length' 2>/dev/null || echo 0)
if [ "${COUNT:-0}" -eq 0 ]; then
  echo "post-merge-check: no CI runs registered within ${GRACE}s grace; no CI configured? exiting"
  exit 0
fi

# Phase 2: poll until every run reaches `completed` or we time out.
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
  RUNS_JSON=$(gh api "repos/$REPO/actions/runs?head_sha=$MERGE_SHA" --jq '.workflow_runs // []' 2>/dev/null || echo "[]")
  INCOMPLETE=$(echo "$RUNS_JSON" | jq '[.[] | select(.status != "completed")] | length')

  if [ "${INCOMPLETE:-0}" -eq 0 ]; then
    # All done — evaluate conclusions.
    BAD=$(echo "$RUNS_JSON" | jq -r '
      [.[] | select(.conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral")
           | "\(.name) (\(.conclusion))"
      ] | join(", ")
    ')
    if [ -z "$BAD" ]; then
      echo "post-merge-check: all CI runs green on $SHORT_SHA"

      # Optional smoke test: only runs when state file + task num were provided.
      if [ -n "$STATE_FILE" ] && [ -n "$TASK_NUM" ] && [ -f "$STATE_FILE" ]; then
        SMOKE_CMD=$(jq -r --arg n "$TASK_NUM" '.tasks[$n].smoke_test // empty' "$STATE_FILE" 2>/dev/null || true)
        if [ -n "$SMOKE_CMD" ]; then
          run_smoke_test "$PR_NUM" "$TASK_NUM" "$SMOKE_CMD" || exit 3
        fi
      fi

      echo "post-merge-check: done"
      exit 0
    fi

    REVERT_CMD="git revert $MERGE_SHA"
    echo "post-merge-check: CI RED on $SHORT_SHA — $BAD"
    if [ -x "$NOTIFY" ]; then
      bash "$NOTIFY" "main CI red after PR #$PR_NUM" \
        "Commit $SHORT_SHA broke main CI: $BAD. Suggested revert: \`$REVERT_CMD\` (review first — orchestrator does not auto-revert)."
    fi
    exit 2
  fi

  sleep "$POLL"
  elapsed=$((elapsed + POLL))
done

echo "post-merge-check: timeout (${TIMEOUT}s) waiting for CI completion on $SHORT_SHA — abandoning watch"
exit 0
