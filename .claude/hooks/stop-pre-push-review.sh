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

# Detect orchestrator-driven session via active plan state file.
STATE_FILE=$(ls -t .claude/plans/*.state.json 2>/dev/null \
  | xargs -I {} sh -c 'jq -er ".status == \"in_progress\"" {} >/dev/null 2>&1 && echo {}' \
  | tail -1)

# Not orchestrator-driven: human session, allow stop unconditionally.
[ -z "$STATE_FILE" ] && exit 0

# Orchestrator-driven: smoke-check that the worker produced something.
# Prefer origin/main as the base; fall back to local main if origin missing.
DIFF=$(git diff origin/main...HEAD 2>/dev/null) \
  || DIFF=$(git diff main...HEAD 2>/dev/null) \
  || DIFF=""

if [ -z "$DIFF" ]; then
  cat >&2 <<EOF
stop hook: no diff vs origin/main — worker produced nothing.

The post-push reviewer would have nothing to review and the push
would fail. Treating this as a worker bug rather than a clean exit.
EOF
  exit 2
fi

exit 0
