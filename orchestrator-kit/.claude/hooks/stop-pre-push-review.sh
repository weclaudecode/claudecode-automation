#!/usr/bin/env bash
# Stop hook (Phase 2+): post-push review moved to the orchestrator tick.
#
# Before Phase 2 this hook spawned a fresh `claude -p` reviewer in-process
# and could block Stop to drive an iteration loop (exit 2 with findings).
# That model worked for sequential execution but doesn't fit the new
# parallel-PR design — review now happens in a separate tick phase
# against the open PR via `review-pr.sh`.
#
# This hook's remaining job is a smoke check: when running under the
# orchestrator, confirm the worker actually produced a diff vs main.
# A zero-diff worker is a silent failure mode today (the downstream
# push would fail with a confusing error); blocking Stop here surfaces
# it immediately.
#
# Exit codes:
#   0  Stop allowed (human session OR diff present in orchestrator session)
#   2  Stop blocked (orchestrator session with no diff vs origin/main)
#
# Env:
#   SKIP_REVIEW=1  Unconditionally allow Stop. Used by reviewer-spawned
#                  child processes (legacy) and by operators debugging
#                  manually.

set -uo pipefail

[ "${SKIP_REVIEW:-0}" = "1" ] && exit 0

REPO=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$REPO"

# Detect orchestrator-driven session.
#
# An in_progress state file alone is NOT sufficient — a plan can be
# in_progress while the operator is implementing it manually in an
# interactive Claude Code session (no worktree, no claude/plan-* branch).
# That false positive blocked Stop on dogfood / source repos where plans
# get authored but the orchestrator never ticks against them.
#
# A real worker session has at least one of:
#   1. Branch matches claude/plan-NN-task-M (launch-worker.sh convention)
#   2. CWD ends in /wt-planNN-tM (launch-worker.sh worktree convention)
# Either is enough; require at least one in addition to the state file.

STATE_FILE=$(ls -t .claude/plans/*.state.json 2>/dev/null \
  | xargs -I {} sh -c 'jq -er ".status == \"in_progress\"" {} >/dev/null 2>&1 && echo {}' \
  | tail -1)
[ -z "$STATE_FILE" ] && exit 0

CURRENT_BRANCH=$(git symbolic-ref --short -q HEAD 2>/dev/null || echo "")
case "$CURRENT_BRANCH" in
  claude/plan-*-task-*) WORKER_SESSION=1 ;;
  *)                    WORKER_SESSION=0 ;;
esac

if [ "$WORKER_SESSION" -eq 0 ]; then
  case "$PWD" in
    *"/wt-plan"*"-t"*)  WORKER_SESSION=1 ;;
  esac
fi

# Interactive session (or operator manually editing): the plan-state signal
# alone is not enough. Let Stop through without checking diff.
[ "$WORKER_SESSION" -eq 0 ] && exit 0

# Orchestrator-driven: smoke-check that the worker produced something.
# Prefer origin/main as the base; fall back to local main if origin missing.
DIFF=$(git diff origin/main...HEAD 2>/dev/null) \
  || DIFF=$(git diff main...HEAD 2>/dev/null) \
  || DIFF=""

if [ -z "$DIFF" ]; then
  cat >&2 <<EOF
stop hook: no diff vs origin/main — worker produced nothing.

Branch: $CURRENT_BRANCH
CWD:    $PWD

The post-push reviewer would have nothing to review and the push
would fail. Treating this as a worker bug rather than a clean exit.
EOF
  exit 2
fi

exit 0
