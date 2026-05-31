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

# ---- get_orchestrator_lock_path ----
# Return the env-namespaced orchestrator tick lock path.
# Usage:
#   lock_path=$(get_orchestrator_lock_path <env>)
# env defaults to "dev" if empty or unset.
get_orchestrator_lock_path() {
  local env="${1:-dev}"
  echo ".claude/state/${env}/orchestrator.lock"
}

# ---- acquire_stack_lock / release_stack_lock ----
# Per-stack deploy lock to serialize workers that touch the same
# CloudFormation stack. Lock dir: .claude/state/<env>/cdk-stack-locks/<name>.lock.d/
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
# acquire_stack_lock <stack-name> [env]
#   env defaults to "dev" if omitted.
#   Returns:
#     0 — lock acquired (or already held by $$)
#     1 — lock held by a live process (not us)
#
# release_stack_lock <stack-name> [env]
#   env defaults to "dev" if omitted.
#   Returns:
#     0 — lock released (or already absent)
#     1 — lock held by a different live PID (won't break it)

# _STACK_LOCK_BASE is kept for backward-compat reference but is no longer
# used directly — callers always go through _stack_lock_base_for_env().
_STACK_LOCK_BASE=".claude/state/cdk-stack-locks"

# Build the per-env base path for stack locks.
# Separate function so it's easily testable and consistent between acquire/release.
_stack_lock_base_for_env() {
  local env="${1:-dev}"
  echo ".claude/state/${env}/cdk-stack-locks"
}

acquire_stack_lock() {
  local stack_name="$1"
  local env="${2:-dev}"
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

  local _lock_base
  _lock_base=$(_stack_lock_base_for_env "$env")
  local lockdir="$repo_root/$_lock_base/${stack_name}.lock.d"
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
  local env="${2:-dev}"
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

  local _lock_base
  _lock_base=$(_stack_lock_base_for_env "$env")
  local lockdir="$repo_root/$_lock_base/${stack_name}.lock.d"

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

# ---- emit_event ----
# Append one JSON line to .claude/state/events.jsonl — a structured,
# queryable timeline of orchestrator activity that sits alongside the
# free-text orchestrator.log. Consumers (dashboards, trend reports,
# external observability) parse this instead of grepping the log.
#
# Usage:
#   emit_event <event_type> [extra_json_object]
#
# Example:
#   emit_event task_merged "$(jq -cn --arg p 05 --argjson task 3 --argjson pr 142 \
#     '{plan:$p, task:$task, pr:$pr}')"
#
# Every line carries at least {ts, event}. The optional second argument is a
# JSON object merged into the line; pass it pre-built (jq -cn ...) so values
# keep their types. Best-effort throughout: a missing repo root, unwritable
# state dir, or malformed extra JSON drops the event and returns 0 rather
# than failing the caller. Never put emit_event on a critical path.
#
# Rotation mirrors orchestrator.log: when the file exceeds
# ORCH_EVENTS_MAX_BYTES (default 10 MiB) it is renamed with a UTC timestamp.
emit_event() {
  local event_type="$1"
  local extra="${2:-{\}}"
  command -v jq >/dev/null 2>&1 || return 0

  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  local events_file="$repo_root/.claude/state/events.jsonl"
  mkdir -p "$repo_root/.claude/state" 2>/dev/null || return 0

  local max_bytes="${ORCH_EVENTS_MAX_BYTES:-10485760}"
  if [ -f "$events_file" ]; then
    local sz
    sz=$(wc -c < "$events_file" 2>/dev/null | tr -d ' ' || echo 0)
    if [ "${sz:-0}" -gt "$max_bytes" ]; then
      mv "$events_file" "${events_file}.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || true
    fi
  fi

  local line
  line=$(jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg event "$event_type" \
    --argjson extra "$extra" \
    '{ts: $ts, event: $event} + $extra' 2>/dev/null) || return 0

  printf '%s\n' "$line" >> "$events_file" 2>/dev/null || return 0
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

# fallback_non_json_review — synthetic-blocker fallback for a reviewer run
# whose final assistant message was not parseable as JSON.
#
# Used by review-pr.sh when VERDICT_JSON ends up empty. Without a fallback,
# review-pr.sh exits 2 with no marker applied and review-pass.sh re-spawns
# the reviewer on the next tick — at ~$2.19 per failed review and a */5
# default cadence, ~$26/hour until manual intervention (see plan PLAN-08
# rationale).
#
# What this does:
#   1. Strips any prior <!-- orch:review-sha:HEX --> marker from the PR
#      body and appends a new one for HEAD_OID — review-pass.sh treats
#      that as "this SHA already reviewed" and stops re-spawning.
#   2. Applies the orch:review-blocked label so iterate-pass.sh picks the
#      PR up for operator-facing iteration on the next tick.
#   3. Posts a top-level PR comment carrying the reviewer's raw prose
#      (first 40 lines) so the operator can read the verdict.
#
# Idempotency: if the body already carries the marker for the same
# HEAD_OID, the fallback was invoked for this exact SHA on a prior tick —
# return immediately without re-posting the comment so repeated runs
# against the same SHA do not pile up duplicate comments.
#
# Each gh failure degrades to a stderr warning rather than failing the
# fallback. The orchestrator log treats the tick as healthy either way —
# that is the whole point of this code path.
#
# Args:
#   $1  repo         owner/repo for gh
#   $2  pr_num       PR number
#   $3  head_oid     full 40-char SHA of the PR HEAD
#   $4  pr_body      current PR body (used for marker-presence + edit base)
#   $5  result_text  raw reviewer prose (first 40 lines go in the comment)
#
# Returns: 0 always.
fallback_non_json_review() {
  local repo="$1"
  local pr_num="$2"
  local head_oid="$3"
  local pr_body="$4"
  local result_text="$5"

  if printf '%s\n' "$pr_body" | grep -qE "<!-- orch:review-sha:${head_oid} -->"; then
    echo "review-pr: fallback: marker for ${head_oid:0:8} already on PR — skipping (idempotent)"
    return 0
  fi

  local clean_body new_body
  clean_body=$(printf '%s\n' "$pr_body" | sed -E '/<!-- orch:review-sha:[a-f0-9]+ -->/d')
  new_body=$(printf '%s\n\n<!-- orch:review-sha:%s -->\n' "$clean_body" "$head_oid")

  gh pr edit "$pr_num" --repo "$repo" --body "$new_body" >/dev/null 2>&1 \
    || echo "review-pr: fallback warning — failed to update PR body with review-sha marker" >&2

  gh pr edit "$pr_num" --repo "$repo" --add-label "orch:review-blocked" >/dev/null 2>&1 \
    || echo "review-pr: fallback warning — failed to apply orch:review-blocked label" >&2

  local prose_head
  prose_head=$(printf '%s\n' "$result_text" | head -40)
  local comment_body
  comment_body=$(cat <<EOF
**Reviewer produced non-JSON output — synthetic blocker applied.**

The orchestrator's review-pr.sh expects a JSON verdict envelope but the
reviewer returned prose. The raw output (first 40 lines) is below.

Operator action: read the reviewer's prose verdict, decide whether the
PR should be approved or revised, then either (a) merge manually and
apply the marker, or (b) remove \`orch:review-blocked\` and let
iterate-pass run, then re-trigger review.

<details><summary>Raw reviewer output</summary>

\`\`\`
${prose_head}
\`\`\`

</details>
EOF
  )

  gh pr comment "$pr_num" --repo "$repo" --body "$comment_body" >/dev/null 2>&1 \
    || echo "review-pr: fallback warning — failed to post explanatory PR comment" >&2

  echo "review-pr: fallback: non-JSON reviewer output — applied review-sha marker, orch:review-blocked label, and explanatory comment on PR #${pr_num}"
  return 0
}

# Enable PR auto-merge on a clean reviewer verdict, unless the task is
# sensitive (auto_merge_overrides[task] == false). PLAN-12 / closes #42:
# the reviewer is now the merge gate — launch-worker no longer calls
# `gh pr merge --auto` so this is the only auto-merge call site.
#
# Sensitive tasks remain operator-gated via orch:needs-robbie applied by
# launch-worker; this function only no-ops on them. The check uses
# `== false` (not jq's `//` default) because `// true` treats both null
# AND false as "use the default", silently flipping a deliberate false
# back to true — see the same trap documented at launch-worker.sh line 79.
#
# Caller (review-pr.sh) invokes this only when HAS_SAFETY=0 AND HAS_BLOCKER=0
# AND the reviewer ran to completion (post-fallback path). That makes
# REQUEST_CHANGES and fallback_non_json_review automatically merge-safe by
# construction; the function only assumes a clean verdict at its boundary.
#
# Args: <state_file> <task_num> <pr_num> <repo>
# Returns: 0 on auto-merge enabled OR correctly skipped (sensitive);
#          1 on `gh pr merge` failure (PR left open for operator).
maybe_enable_auto_merge() {
  local state_file="$1"
  local task_num="$2"
  local pr_num="$3"
  local repo="$4"

  local override
  override=$(jq -r --arg t "$task_num" \
    'if .auto_merge_overrides[$t] == false then "false" else "true" end' \
    "$state_file" 2>/dev/null)

  if [ "$override" = "false" ]; then
    echo "review-pr: task $task_num is sensitive (auto_merge_overrides=false); skipping auto-merge — orch:needs-robbie label already applied by launch-worker"
    return 0
  fi

  if gh pr merge "$pr_num" --repo "$repo" --auto --squash --delete-branch >/dev/null 2>&1; then
    echo "review-pr: enabled auto-merge on PR #$pr_num (clean verdict — reviewer is the merge gate per PLAN-12)"
    return 0
  fi

  echo "review-pr: warning — gh pr merge --auto failed on PR #$pr_num — leaving PR open for manual merge" >&2
  return 1
}
