#!/usr/bin/env bash
# Sourced helpers for the orchestrator and its phase scripts.
#
# Source this file from any script that needs:
#   - Concurrency-safe state.json writes (state_write)
#   - Worktree manifest tracking (register/unregister + cleanup_active_worktrees)
#   - Timeout binary detection (find_timeout_cmd)
#
# Usage:
#   source "$REPO/.claude/scripts/_dispatcher_lib.sh"
#
# All functions are POSIX-bash compatible (no associative arrays, no
# bash-4.3 idioms like `wait -n`) so they work on macOS bash 3.2.

# ---- Worktree manifest path (relative to repo root) ----
# Each line is a worktree path that a worker has live. The orchestrator
# tick's EXIT/INT/TERM trap reads this and removes any survivors —
# workers killed mid-spawn leak their worktrees otherwise.
ACTIVE_WORKTREES_FILE=".claude/state/active_worktrees.txt"

# ---- state_write ----
# Atomic state.json update with a per-state-file lock.
#
# Usage:
#   state_write <state_file> <jq_expr> [jq_args...]
#
# Example:
#   state_write "$STATE_FILE" '.tasks[$t].status = "merged"' --arg t "$TASK_NUM"
#
# Concurrency model: mkdir-based lockdir (`<state>.lock.d`). Portable
# across macOS/BSD/Linux without requiring `flock(1)` from util-linux.
# Acquisition waits up to ORCH_STATE_LOCK_TIMEOUT seconds (default 10),
# then checks for stale lock (PID dead) and breaks if so.
#
# Returns:
#   0 — state file updated successfully
#   1 — jq evaluation failed (state file untouched, no partial write)
#   2 — lock acquisition timed out (state file untouched)
state_write() {
  local state_file="$1"
  local jq_expr="$2"
  shift 2

  local lockdir="${state_file}.lock.d"
  local timeout="${ORCH_STATE_LOCK_TIMEOUT:-10}"
  local max_iters=$((timeout * 10))
  local waited=0

  while ! mkdir "$lockdir" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    if [ "$waited" -ge "$max_iters" ]; then
      local stale_pid
      stale_pid=$(cat "$lockdir/pid" 2>/dev/null || echo "")
      if [ -n "$stale_pid" ] && ! kill -0 "$stale_pid" 2>/dev/null; then
        echo "state_write: breaking stale lock (dead PID $stale_pid) on $state_file" >&2
        rm -rf "$lockdir" 2>/dev/null
        waited=0
        continue
      fi
      echo "state_write: timed out after ${timeout}s waiting for lock on $state_file (holder PID ${stale_pid:-?})" >&2
      return 2
    fi
  done

  echo "$$" > "$lockdir/pid"

  local rc=0
  local jq_err
  if jq_err=$(jq "$@" "$jq_expr" "$state_file" 2>&1 > "$state_file.tmp"); then
    mv "$state_file.tmp" "$state_file"
  else
    rm -f "$state_file.tmp"
    echo "state_write: jq failed on $state_file: $jq_err" >&2
    rc=1
  fi

  rm -rf "$lockdir" 2>/dev/null
  return "$rc"
}

# ---- register_worktree / unregister_worktree ----
#
# Workers call register_worktree right after `git worktree add` succeeds,
# and call unregister_worktree at every GRACEFUL exit path (success,
# retry-leaving-worktree, hard-block-leaving-worktree). Signal-induced
# exits (SIGKILL, untrapped SIGTERM) intentionally skip unregistration so
# the orchestrator's trap will clean the leaked worktree.
#
# The manifest is shared across all workers in a tick — appending is
# atomic for small writes on POSIX (PIPE_BUF), but with MAX_PARALLEL > 1
# we add a tiny lockdir for safety.

register_worktree() {
  local wt="$1"
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  local manifest="$repo_root/$ACTIVE_WORKTREES_FILE"
  mkdir -p "$(dirname "$manifest")"
  _worktree_manifest_lock "$repo_root" || return 1
  echo "$wt" >> "$manifest"
  _worktree_manifest_unlock "$repo_root"
}

unregister_worktree() {
  local wt="$1"
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  local manifest="$repo_root/$ACTIVE_WORKTREES_FILE"
  [ -f "$manifest" ] || return 0
  _worktree_manifest_lock "$repo_root" || return 1
  if grep -vFx "$wt" "$manifest" > "$manifest.tmp" 2>/dev/null; then
    mv "$manifest.tmp" "$manifest"
  else
    # grep -v exits 1 if nothing matches — that means manifest had ONLY
    # this wt line and is now empty. Treat as success.
    rm -f "$manifest.tmp"
    : > "$manifest"
  fi
  # Cosmetic: drop empty manifest so cleanup_active_worktrees no-ops fast.
  [ -s "$manifest" ] || rm -f "$manifest"
  _worktree_manifest_unlock "$repo_root"
}

# Best-effort: remove every worktree path still in the manifest, then drop
# the manifest. Called by the orchestrator's EXIT/INT/TERM trap and again
# at tick start to mop up after a SIGKILLed prior tick.
cleanup_active_worktrees() {
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  local manifest="$repo_root/$ACTIVE_WORKTREES_FILE"
  [ -f "$manifest" ] || return 0

  _worktree_manifest_lock "$repo_root" || return 1

  local cleaned=0
  local missing=0
  while IFS= read -r wt; do
    [ -z "$wt" ] && continue
    if [ -d "$wt" ]; then
      if git -C "$repo_root" worktree remove "$wt" --force >/dev/null 2>&1; then
        cleaned=$((cleaned + 1))
      else
        # Worktree dir existed but git refused — try removing the dir
        # outright so we don't pile up across ticks.
        rm -rf "$wt" 2>/dev/null && cleaned=$((cleaned + 1)) || true
      fi
    else
      missing=$((missing + 1))
    fi
  done < "$manifest"

  rm -f "$manifest"
  _worktree_manifest_unlock "$repo_root"

  if [ "$cleaned" -gt 0 ]; then
    git -C "$repo_root" worktree prune >/dev/null 2>&1 || true
    echo "cleanup_active_worktrees: removed $cleaned orphan worktree(s) ($missing already gone)"
  fi
}

# Private — short critical-section lock around the manifest file.
_worktree_manifest_lock() {
  local repo_root="$1"
  local lockdir="$repo_root/$ACTIVE_WORKTREES_FILE.lock.d"
  local waited=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    sleep 0.05
    waited=$((waited + 1))
    if [ "$waited" -ge 100 ]; then
      local stale_pid
      stale_pid=$(cat "$lockdir/pid" 2>/dev/null || echo "")
      if [ -n "$stale_pid" ] && ! kill -0 "$stale_pid" 2>/dev/null; then
        rm -rf "$lockdir" 2>/dev/null
        waited=0
        continue
      fi
      echo "_worktree_manifest_lock: timeout (5s) on $lockdir" >&2
      return 1
    fi
  done
  echo "$$" > "$lockdir/pid"
}

_worktree_manifest_unlock() {
  local repo_root="$1"
  rm -rf "$repo_root/$ACTIVE_WORKTREES_FILE.lock.d" 2>/dev/null
}

# ---- cascade_block ----
# When a task transitions to status: blocked, mark every transitive
# pending dependent as blocked too. Without this, downstream tasks
# whose dep-issue never closes stay pending forever, refresh-deps
# never adds orch:deps-met, find-ready-tasks never emits them, and
# the plan-completion check sees pending > 0 → plan never archives.
#
# Usage:
#   cascade_block <state_file> <root_task_num>
#
# Policy (only-pending): we cascade ONLY tasks currently in `pending`.
# in_progress / in_review tasks are sibling workers' live PRs; force-
# blocking them would race with the worker's own state writes and
# could resurrect a blocked entry on the next update. merged tasks
# are already done. blocked tasks need no re-block.
#
# Idempotent: the jq filter checks status == "pending" before writing,
# so concurrent re-runs (or a sibling racing the BFS) cause no-op
# rather than incoherent state.
#
# blocked_reason carries the ROOT blocker's number (not the immediate
# parent) so the audit trail points at the original cause.
#
# Returns:
#   0 — cascade complete (zero or more tasks transitioned)
#   1 — python BFS failed or state_write rejected (logged to stderr)
cascade_block() {
  local state_file="$1"
  local root_task="$2"

  if ! command -v python3 >/dev/null; then
    echo "cascade_block: python3 required" >&2
    return 1
  fi

  local downstream
  # Python emits one task number per line so the bash `while read` loop is
  # shell-agnostic. Earlier draft used space-separated + `for x in $var`,
  # which works in bash but is a single-iteration with the whole string in
  # zsh — landmine if anyone sources this lib from zsh.
  downstream=$(python3 - "$state_file" "$root_task" <<'PY'
import json, sys
state_path, root = sys.argv[1], sys.argv[2]
try:
    with open(state_path) as f:
        state = json.load(f)
except (OSError, json.JSONDecodeError) as exc:
    print(f"cascade_block: cannot read state: {exc}", file=sys.stderr)
    sys.exit(1)

tasks = state.get("tasks", {})
if root not in tasks:
    print(f"cascade_block: root task {root} not in state.tasks", file=sys.stderr)
    sys.exit(1)

reverse = {}
for k, t in tasks.items():
    for dep in t.get("depends_on", []):
        reverse.setdefault(str(dep), []).append(k)

visited = set()
queue = [root]
out = []
while queue:
    cur = queue.pop(0)
    for dep in reverse.get(cur, []):
        if dep in visited:
            continue
        visited.add(dep)
        if tasks[dep].get("status") != "pending":
            continue
        out.append(dep)
        queue.append(dep)
for n in out:
    print(n)
PY
  ) || return 1

  [ -z "$downstream" ] && return 0

  local reason="upstream_blocked_t${root_task}"
  local cascaded=0
  local cascaded_list=""
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    if state_write "$state_file" \
      'if .tasks[$t].status == "pending"
       then .tasks[$t].status = "blocked"
            | .tasks[$t].blocked_at = (now | todateiso8601)
            | .tasks[$t].blocked_reason = $r
       else . end' \
      --arg t "$dep" --arg r "$reason"; then
      cascaded=$((cascaded + 1))
      cascaded_list="${cascaded_list}${cascaded_list:+ }${dep}"
    else
      echo "cascade_block: state_write failed for task $dep (root=t${root_task})" >&2
    fi
  done <<< "$downstream"
  echo "cascade_block: marked $cascaded task(s) blocked downstream of t${root_task}: $cascaded_list"
  return 0
}

# ---- resolve_auto_recommended ----
# Echo the effective AUTO_RECOMMENDED value ("0" or "1") that workers
# will see for a given plan's state file. Precedence:
#   state.auto_recommended (per-plan, true|false)
#     > $ORCH_AUTO_RECOMMENDED (env var)
#     > built-in default 0
#
# Uses jq's `has()` check rather than `// empty` because jq's `//` triggers
# on `false` as well as `null` — a per-plan `false` would otherwise fall
# through to the env var. Same trap previously fixed at launch-worker.sh.
#
# Returns:
#   0 — always (prints "0" or "1" to stdout)
resolve_auto_recommended() {
  local state_file="$1"
  local plan_val
  plan_val=$(jq -r 'if has("auto_recommended") then .auto_recommended else "" end' "$state_file" 2>/dev/null)
  case "$plan_val" in
    true)  echo 1 ;;
    false) echo 0 ;;
    *)     echo "${ORCH_AUTO_RECOMMENDED:-0}" ;;
  esac
}

# ---- find_timeout_cmd ----
# Print the path to a timeout(1) binary, or empty string if none is
# available. Callers should fall back to running without a timeout (with
# a warning), so this never errors.
#
# - Linux: `timeout` from coreutils (always present).
# - macOS: `gtimeout` from `brew install coreutils`; not in stock macOS.
find_timeout_cmd() {
  command -v timeout 2>/dev/null \
    || command -v gtimeout 2>/dev/null \
    || true
}
