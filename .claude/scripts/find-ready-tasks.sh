#!/usr/bin/env bash
# Emit up to N task numbers ready for launch.
#
# Usage: find-ready-tasks.sh <state_file> <max_tasks> [<owner/repo>]
#
# A task is "ready" iff ALL of:
#   - tasks.N.status == "pending"
#   - tasks.N.issue is set
#   - that issue has the `orch:deps-met` label on GitHub
#   - tasks.N.touches do NOT collide (after glob expansion) with any
#     already-emitted candidate this call, nor with any task currently
#     in {in_progress, in_review} (file collision detection — Phase 4).
#
# Output: up to <max_tasks> task numbers, one per line, in numerical
# order. Empty output is valid (nothing ready).
#
# Glob intersection model (per SDLC-EVOLUTION-PLAN Task 4.1):
#   Expand each side's touches: against the worktree file list (Python
#   glob.glob with recursive=True); two entries collide iff their
#   expanded concrete-path sets share any file. Literal paths that name
#   files not yet tracked expand to the empty set — those collide only
#   at push/merge time, which Task 4.4's rebase-pr.sh handles.
#
# Optimization: one `gh issue list --label orch:task --label orch:deps-met
# --state open` call returns ALL eligible issues; we intersect with the
# pending tasks in state.json. O(1) HTTP calls regardless of plan size.
#
# Exit codes:
#   0  output emitted (may be empty)
#   1  environment/args failure

set -uo pipefail

command -v jq >/dev/null || { echo "find-ready: jq required" >&2; exit 1; }
command -v gh >/dev/null || { echo "find-ready: gh required" >&2; exit 1; }
command -v python3 >/dev/null || {
  echo "find-ready: python3 required (used for glob expansion)" >&2
  exit 1
}

if [ $# -lt 2 ]; then
  echo "usage: $0 <state_file> <max_tasks> [<owner/repo>]" >&2
  exit 1
fi

STATE_FILE="$1"
MAX="$2"
REPO="${3:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"

[ -f "$STATE_FILE" ] || { echo "find-ready: state file not found: $STATE_FILE" >&2; exit 1; }
[[ "$MAX" =~ ^[0-9]+$ ]] || { echo "find-ready: max_tasks must be numeric, got '$MAX'" >&2; exit 1; }
[ -n "$REPO" ] || {
  echo "find-ready: no repo specified and gh auto-detect failed" >&2
  echo "  pass <owner/repo> as 3rd arg or run from a gh-tracked clone" >&2
  exit 1
}

# v2 schema check
jq -e '.tasks | type == "object"' "$STATE_FILE" >/dev/null 2>&1 || {
  echo "find-ready: state file lacks .tasks object (expected v2 schema): $STATE_FILE" >&2
  exit 1
}

# Zero slots → nothing to emit. Exit 0 silently.
[ "$MAX" -eq 0 ] && exit 0

# Build map: pending task_num -> issue_num. Filter out tasks with no
# linked issue (they can't have a label, so they can't be deps-met).
PENDING=$(jq -r '
  .tasks | to_entries[]
  | select(.value.status == "pending" and .value.issue != null)
  | "\(.key) \(.value.issue)"
' "$STATE_FILE")

if [ -z "$PENDING" ]; then
  exit 0
fi

# Single gh call: get all open deps-met-labeled task issues.
DEPS_MET_ISSUES=$(gh issue list \
  --repo "$REPO" \
  --label "orch:task" \
  --label "orch:deps-met" \
  --state open \
  --json number \
  --limit 200 \
  --jq '[.[].number] | join(" ")' 2>/dev/null || echo "")

if [ -z "$DEPS_MET_ISSUES" ]; then
  exit 0
fi

# Glob-aware collision filter. Python loads state.json, expands touches
# globs against the cwd file tree, and emits the safe task numbers.
# We pass state path, MAX, and deps-met issue set on argv; Python does
# the rest in one process (cheaper than per-candidate subshells).
#
# IMPORTANT: cwd here is the orchestrator's repo root — glob expansion
# uses that tree. Workers run in worktrees off the same commit, so the
# expanded file sets match what each worker will see when it starts.
python3 - "$STATE_FILE" "$MAX" "$DEPS_MET_ISSUES" <<'PY'
import json, sys, glob

state_path = sys.argv[1]
max_emit = int(sys.argv[2])
deps_met_issues = set(sys.argv[3].split()) if sys.argv[3] else set()

with open(state_path) as f:
    state = json.load(f)

tasks = state.get('tasks', {})

def expand(touches):
    """Expand a list of gitignore-syntax globs against cwd. Returns the
    concrete set of paths that currently exist. Literal entries for
    non-existent files expand to nothing — collision with such paths is
    caught later by Task 4.4's rebase-pr.sh, not here."""
    paths = set()
    for g in touches or []:
        paths.update(glob.glob(g, recursive=True))
    return paths

# In-flight = anything still consuming a worker slot or owning an open PR.
# Both states are file-claims we must not collide with.
in_flight_paths = set()
for tnum, t in tasks.items():
    if t.get('status') in ('in_progress', 'in_review'):
        in_flight_paths |= expand(t.get('touches', []))

# Iterate pending+deps-met in numerical task order. Emit non-colliding
# ones; merge each emission's paths into in_flight_paths so the next
# candidate in the same tick sees them too.
emitted = 0
for tnum in sorted(tasks.keys(), key=lambda k: int(k)):
    if emitted >= max_emit:
        break
    t = tasks[tnum]
    if t.get('status') != 'pending':
        continue
    issue = t.get('issue')
    if issue is None or str(issue) not in deps_met_issues:
        continue
    candidate_paths = expand(t.get('touches', []))
    if candidate_paths & in_flight_paths:
        continue
    print(tnum)
    in_flight_paths |= candidate_paths
    emitted += 1
PY

exit 0
