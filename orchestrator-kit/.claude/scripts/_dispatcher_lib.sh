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
  if jq "$@" "$jq_expr" "$state_file" > "$state_file.tmp" 2>/dev/null; then
    mv "$state_file.tmp" "$state_file"
  else
    rm -f "$state_file.tmp"
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
