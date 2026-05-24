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

# ---- acquire_stack_lock / release_stack_lock ----
# Per-stack deploy lock to serialize workers that touch the same
# CloudFormation stack. Lock dir: .claude/state/cdk-stack-locks/<name>.lock.d/
# with a PID file inside, mirroring state_write's lock pattern.
#
# Design choice: FAIL-FAST. If the lock is held by a live process,
# acquire_stack_lock exits 1 immediately. The caller (T8's deploy tracker)
# can decide whether to retry on the next orchestrator tick. This avoids
# blocking the tick while a long CDK deploy holds the lock in another process.
#
# Idempotent on same-PID reacquire: a process that already holds the lock
# can call acquire_stack_lock again and will get exit 0.
#
# acquire_stack_lock <stack-name>
#   Returns:
#     0 — lock acquired (or already held by $$)
#     1 — lock held by a live process (not us)
#
# release_stack_lock <stack-name>
#   Returns:
#     0 — lock released (or already absent)
#     1 — lock held by a different live PID (won't break it)

_STACK_LOCK_BASE=".claude/state/cdk-stack-locks"

acquire_stack_lock() {
  local stack_name="$1"
  if [ -z "$stack_name" ]; then
    echo "acquire_stack_lock: stack-name required" >&2
    return 1
  fi

  # Reject anything that could escape the lock-base dir (path traversal via
  # `../foo`, absolute paths via `/foo`, slashes that nest under a sibling
  # tree, NULs, spaces). CloudFormation stack names are constrained to
  # ^[A-Za-z][A-Za-z0-9-]*$ per AWS spec — the regex below is intentionally
  # looser (allows underscore + dot) but rejects every traversal character.
  if [[ ! "$stack_name" =~ ^[A-Za-z0-9_.-]+$ ]] \
     || [[ "$stack_name" = "." ]] \
     || [[ "$stack_name" = ".." ]]; then
    echo "acquire_stack_lock: invalid stack name '$stack_name' (allowed: A-Z a-z 0-9 _ . -; not '.' or '..')" >&2
    return 1
  fi

  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "acquire_stack_lock: cannot determine repo root" >&2
    return 1
  }

  local lockdir="$repo_root/$_STACK_LOCK_BASE/${stack_name}.lock.d"
  mkdir -p "$(dirname "$lockdir")"

  # Try to create the lock atomically.
  if mkdir "$lockdir" 2>/dev/null; then
    echo "$$" > "$lockdir/pid"
    return 0
  fi

  # Lock dir exists — read the existing holder.
  # NOTE: tiny TOCTOU window here — if the holder mkdir'd but crashed before
  # writing $lockdir/pid, the read below yields "" and we treat it as stale
  # and break the lock. Same race accepted in state_write and
  # _worktree_manifest_lock; resolving it would need an fsync-friendly
  # atomic write that isn't portable across bash 3.2 + BSD coreutils.
  local held_pid
  held_pid=$(cat "$lockdir/pid" 2>/dev/null || echo "")

  # Same-PID: idempotent success (reentrant caller).
  if [ -n "$held_pid" ] && [ "$held_pid" = "$$" ]; then
    return 0
  fi

  # Different PID: check liveness.
  if [ -n "$held_pid" ] && kill -0 "$held_pid" 2>/dev/null; then
    # Alive — fail-fast so the orchestrator tick is not blocked.
    echo "acquire_stack_lock: stack '$stack_name' held by live PID $held_pid" >&2
    return 1
  fi

  # Dead PID (or empty PID file) — stale lock; break it and retry once.
  echo "acquire_stack_lock: breaking stale lock (dead PID ${held_pid:-?}) on stack '$stack_name'" >&2
  rm -rf "$lockdir" 2>/dev/null
  if mkdir "$lockdir" 2>/dev/null; then
    echo "$$" > "$lockdir/pid"
    return 0
  fi

  # Still can't acquire after stale-break — another process raced us.
  held_pid=$(cat "$lockdir/pid" 2>/dev/null || echo "")
  echo "acquire_stack_lock: stack '$stack_name' acquired by racing PID ${held_pid:-?}" >&2
  return 1
}

release_stack_lock() {
  local stack_name="$1"
  if [ -z "$stack_name" ]; then
    echo "release_stack_lock: stack-name required" >&2
    return 1
  fi

  # Same path-traversal guard as acquire — refuse to rm -rf any path the
  # caller couldn't legitimately have acquired.
  if [[ ! "$stack_name" =~ ^[A-Za-z0-9_.-]+$ ]] \
     || [[ "$stack_name" = "." ]] \
     || [[ "$stack_name" = ".." ]]; then
    echo "release_stack_lock: invalid stack name '$stack_name' (allowed: A-Z a-z 0-9 _ . -; not '.' or '..')" >&2
    return 1
  fi

  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "release_stack_lock: cannot determine repo root" >&2
    return 1
  }

  local lockdir="$repo_root/$_STACK_LOCK_BASE/${stack_name}.lock.d"

  # No lock dir — idempotent success (already released or never acquired).
  [ -d "$lockdir" ] || return 0

  local held_pid
  held_pid=$(cat "$lockdir/pid" 2>/dev/null || echo "")

  # Sentinel: locks acquired on behalf of a disowned child (T8 autonomous
  # deploys) record "orchestrator:external" in the PID file. The actual cdk
  # PID is captured in the deploy-status JSON, not here. Treat the sentinel
  # as owner-relinquishable: deploy-watch may release it without warning.
  if [ "$held_pid" = "orchestrator:external" ]; then
    rm -rf "$lockdir" 2>/dev/null
    return 0
  fi

  if [ -n "$held_pid" ] && [ "$held_pid" != "$$" ]; then
    # Check if it's a live PID we shouldn't stomp.
    if kill -0 "$held_pid" 2>/dev/null; then
      echo "release_stack_lock: stack '$stack_name' is held by PID $held_pid (not us — $$), refusing to release" >&2
      return 1
    fi
    # Dead — safe to clean up even though the PID differs.
    echo "release_stack_lock: removing stale lock (dead PID $held_pid) on stack '$stack_name'" >&2
  fi

  rm -rf "$lockdir" 2>/dev/null
  return 0
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

# ---- extract_usage_summary ----
# Parse a `claude -p --output-format json` run file's terminal "result"
# message and emit a one-line usage summary. Format:
#
#   tokens={in:N out:N cache_r:N cache_w:N} cost=$N model=NAME turns=N duration=Ns
#
# Trusts claude's own `total_cost_usd` and `modelUsage` fields rather than
# maintaining a pricing table that drifts when Anthropic changes prices.
# Emits empty string (and returns 0) if the run file is missing or doesn't
# contain a parseable result message — callers should treat that as
# "no usage to report" rather than an error.
extract_usage_summary() {
  local run_json="$1"
  [ -f "$run_json" ] || { echo ""; return 0; }
  jq -r '
    last |
    if .type == "result" then
      "tokens={in:\(.usage.input_tokens // 0) " +
      "out:\(.usage.output_tokens // 0) " +
      "cache_r:\(.usage.cache_read_input_tokens // 0) " +
      "cache_w:\(.usage.cache_creation_input_tokens // 0)} " +
      "cost=$\((.total_cost_usd // 0) * 10000 | round / 10000) " +
      "model=\((.modelUsage // {}) | (keys | .[0] // "?") | sub("^claude-"; "")) " +
      "turns=\(.num_turns // 0) " +
      "duration=\((.duration_ms // 0) / 1000 | round)s"
    else
      ""
    end
  ' "$run_json" 2>/dev/null || echo ""
}

# ---- update_task_usage ----
# Append a run's usage to state.tasks.<N>.usage, accumulating totals and
# preserving a per-run breakdown.
#
# Usage:
#   update_task_usage <state_file> <task_num> <run_json> <run_kind>
#
# run_kind is informational, one of: worker | iterator | reviewer.
# Schema added under state.tasks.<N>.usage:
#   {
#     runs: [{kind, cost_usd, input_tokens, output_tokens,
#             cache_read_input_tokens, cache_creation_input_tokens,
#             num_turns, duration_ms, model, is_error, run_at}],
#     total_cost_usd, total_input_tokens, total_output_tokens,
#     total_cache_read_tokens, total_cache_creation_tokens,
#     total_turns, total_duration_ms,
#     models: [string]  (unique list of models used across runs)
#   }
#
# Failures parsing the run JSON are silent (state untouched, return 0).
# Failures writing state surface as a state_write error to the caller.
update_task_usage() {
  local state_file="$1"
  local task_num="$2"
  local run_json="$3"
  local run_kind="$4"

  [ -f "$run_json" ] || return 0

  local run_obj
  run_obj=$(jq --arg kind "$run_kind" '
    last |
    if .type == "result" then
      {
        kind: $kind,
        cost_usd: (.total_cost_usd // 0),
        input_tokens: (.usage.input_tokens // 0),
        output_tokens: (.usage.output_tokens // 0),
        cache_read_input_tokens: (.usage.cache_read_input_tokens // 0),
        cache_creation_input_tokens: (.usage.cache_creation_input_tokens // 0),
        num_turns: (.num_turns // 0),
        duration_ms: (.duration_ms // 0),
        model: ((.modelUsage // {}) | (keys | .[0] // null)),
        is_error: (.is_error // false),
        run_at: (now | todateiso8601)
      }
    else
      null
    end
  ' "$run_json" 2>/dev/null)

  if [ -z "$run_obj" ] || [ "$run_obj" = "null" ]; then
    return 0
  fi

  state_write "$state_file" '
    .tasks[$t].usage //= {
      runs: [],
      total_cost_usd: 0,
      total_input_tokens: 0,
      total_output_tokens: 0,
      total_cache_read_tokens: 0,
      total_cache_creation_tokens: 0,
      total_turns: 0,
      total_duration_ms: 0,
      models: []
    } |
    .tasks[$t].usage.runs += [$run] |
    .tasks[$t].usage.total_cost_usd += $run.cost_usd |
    .tasks[$t].usage.total_input_tokens += $run.input_tokens |
    .tasks[$t].usage.total_output_tokens += $run.output_tokens |
    .tasks[$t].usage.total_cache_read_tokens += $run.cache_read_input_tokens |
    .tasks[$t].usage.total_cache_creation_tokens += $run.cache_creation_input_tokens |
    .tasks[$t].usage.total_turns += $run.num_turns |
    .tasks[$t].usage.total_duration_ms += $run.duration_ms |
    .tasks[$t].usage.models = ((.tasks[$t].usage.models + [$run.model]) | map(select(. != null)) | unique)
  ' --arg t "$task_num" --argjson run "$run_obj"
}
