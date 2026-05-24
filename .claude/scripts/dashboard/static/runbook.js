"use strict";

// RUNBOOK — operator remediation snippets keyed by error / blocked_reason
// strings the dashboard surfaces. lookupRunbook(s) tries exact match first
// then substring; cascade reasons (upstream_blocked_t<N>) are template-shaped
// so they get their own branch.
//
// Add a key here when the dashboard starts surfacing a new failure mode.
// Keep snippets to <= 8 lines so the popover stays scannable.

const RUNBOOK = {
  // -----------------------------------------------------------------------
  // blocked_reason values from _dispatcher_lib.sh
  // -----------------------------------------------------------------------
  "worker_failed_3x": {
    title: "Worker failed 3 times",
    body: [
      "The worker exited non-zero 3 times in a row. The worktree at",
      "../wt-plan<NN>-t<M>/ is preserved for inspection.",
      "",
      "After fixing, reset task <N> to pending:",
      "  jq '.tasks[\"<N>\"].status=\"pending\"",
      "      | .tasks[\"<N>\"].retries=0",
      "      | del(.tasks[\"<N>\"].blocked_at,.tasks[\"<N>\"].blocked_reason)'",
      "    .claude/plans/PLAN-NN-*.state.json | sponge $_"
    ]
  },
  "iterate_failed_3x": {
    title: "Iterator failed 3 times",
    body: [
      "The iterator could not address reviewer findings after 3 attempts.",
      "Inspect the PR's review comments, then either fix manually and push,",
      "or reset the task to pending so the worker re-runs from scratch.",
      "Same reset snippet as worker_failed_3x — adjust the state file path."
    ]
  },
  "review_iter_cap": {
    title: "Review iteration cap hit",
    body: [
      "The reviewer has rejected this PR ORCH_MAX_TURNS-worth of times.",
      "Either:",
      "  1. Read the latest review comments and address them by hand on the branch",
      "  2. Reset retries and remove the orch:review-blocked label to retry",
      "     gh pr edit <num> --remove-label orch:review-blocked"
    ]
  },
  "pr_closed_unmerged": {
    title: "PR closed without merging",
    body: [
      "A PR was closed (not merged). This cascade-blocks any pending",
      "tasks that depended on it. To recover:",
      "  1. Decide whether to reopen the PR or supersede it",
      "  2. Reset the task to pending and clear cascade-blocks downstream",
      "     (see 'Resuming a blocked plan' in orchestrator-kit/README.md)"
    ]
  },

  // -----------------------------------------------------------------------
  // Substring patterns from collector / fetch errors
  // -----------------------------------------------------------------------
  "gh CLI not found": {
    title: "gh CLI missing",
    body: [
      "The dashboard shells out to gh; it can't find the binary on PATH.",
      "Install + authenticate:",
      "  brew install gh   # macOS",
      "  gh auth login",
      "Then restart the dashboard."
    ]
  },
  "gh timed out": {
    title: "gh call timed out",
    body: [
      "A gh subprocess took longer than 10s. Usually a transient network",
      "issue or GitHub API slowness. The dashboard caches gh responses for",
      "30s, so this auto-recovers on the next successful poll.",
      "If persistent: check `gh api rate_limit` for throttling."
    ]
  },
  "ps timed out": {
    title: "ps command hung",
    body: [
      "The workers panel timed out reading the process table. Usually means",
      "system load is high. Check `uptime` and `top` for runaway processes.",
      "If a worker is stuck, kill its PID:  kill <pid>"
    ]
  },
  "state file unreadable": {
    title: "Plan state file unreadable",
    body: [
      "The active plan's state.json is missing or unparseable. Check:",
      "  ls -la .claude/plans/*.state.json",
      "  jq . .claude/plans/PLAN-NN-*.state.json",
      "If corrupt, restore from git history or re-run ingest-plan.sh."
    ]
  },
  "fetch failed": {
    title: "Dashboard backend unreachable",
    body: [
      "The browser couldn't reach the Flask backend. Likely causes:",
      "  - dashboard.sh stop was called",
      "  - the Python process crashed",
      "  - port collision on ORCH_DASHBOARD_PORT",
      "Restart: ./.claude/scripts/dashboard.sh restart"
    ]
  }
};

const _CASCADE_PREFIX = "upstream_blocked_t";

const _CASCADE_ENTRY = {
  title: "Cascade-blocked by upstream task",
  body: [
    "This task is blocked only because one of its depends_on tasks is",
    "blocked. Fix the upstream first; this task auto-unblocks when the",
    "upstream is reset to pending and re-runs successfully.",
    "",
    "To clear all cascade blocks at once:",
    "  jq '.tasks |= with_entries(",
    "    if (.value.blocked_reason // \"\") | startswith(\"upstream_blocked_\")",
    "    then .value.status=\"pending\" | .value.retries=0",
    "         | .value |= del(.blocked_at,.blocked_reason)",
    "    else . end)' .claude/plans/PLAN-NN-*.state.json | sponge $_"
  ]
};

function lookupRunbook(s) {
  if (!s || typeof s !== "string") return null;
  if (s.startsWith(_CASCADE_PREFIX)) return _CASCADE_ENTRY;
  if (Object.prototype.hasOwnProperty.call(RUNBOOK, s)) return RUNBOOK[s];
  for (const key of Object.keys(RUNBOOK)) {
    if (s.indexOf(key) >= 0) return RUNBOOK[key];
  }
  return null;
}

// Exposed on window so dashboard.js can call without an import system.
window.RUNBOOK = RUNBOOK;
window.lookupRunbook = lookupRunbook;
