# Claude Code Plan Orchestrator

Autonomous loop that executes superpower-style plans task-by-task with
pre-push review and conditional auto-merge.

## Prerequisites

- macOS or Linux
- `claude` CLI authenticated with your Max plan (`claude /login`)
- `gh` CLI authenticated (`gh auth login`)
- `jq`, `git`
- **`gawk`** (GNU awk) — required. BSD awk silently no-ops the array-capture
  syntax used by the sensitive-pattern detector, so without gawk every plan
  ingests with `auto_merge_overrides: {}` and IAM/migration tasks would
  auto-merge.
- A GitHub repo with `main` branch and branch protection allowing `--auto` merges
- Optional: cron / launchd for scheduled triggers

```bash
brew install gh jq gawk     # macOS — gawk is required
# Linux:  apt-get install gh jq gawk  (or distro equivalent)
# claude install: see https://docs.claude.com/en/docs/claude-code/setup
```

## Install into a repo

From your repo root:

```bash
# Copy this kit into the repo
cp -r /path/to/this/kit/.claude .
cp /path/to/this/kit/orchestrator.sh .
cp /path/to/this/kit/CLAUDE.md .   # only if you don't already have one — review carefully

chmod +x orchestrator.sh
chmod +x .claude/hooks/*.sh
chmod +x .claude/scripts/*.sh

# Add to .gitignore
cat >> .gitignore <<'EOF'

# Claude Code orchestrator runtime state
.claude/state/orchestrator.lock/
.claude/state/run-*.json
.claude/state/post-merge-pr*.log
.claude/state/active_worktrees.txt
EOF
```

Then customize:

1. Edit `CLAUDE.md` — your stack, conventions, must-rules
2. Edit `.claude/defaults.md` — your "when in doubt" rules
3. Optionally edit `.claude/state/decisions.md` to seed prior decisions

## Required permissions allowlist

The worker runs with `--permission-mode acceptEdits`, which only auto-accepts
file edits. Bash commands (running tests, committing, filing follow-up
issues) still go through the regular permission system. Without an allowlist
the worker will stall on the first bash command, hit `--max-turns`, fail,
retry 3×, and mark the plan blocked.

Add a `permissions.allow` block to `.claude/settings.json` alongside the
existing `hooks` section. Tighten the list to your project's actual commands:

```json
{
  "permissions": {
    "allow": [
      "Bash(git add:*)", "Bash(git commit:*)", "Bash(git diff:*)",
      "Bash(git status:*)", "Bash(git log:*)", "Bash(git rm:*)", "Bash(git mv:*)",
      "Bash(pytest:*)", "Bash(uv:*)", "Bash(uv run:*)",
      "Bash(pnpm:*)", "Bash(npm:*)", "Bash(npx:*)",
      "Bash(gh issue create:*)", "Bash(gh issue list:*)"
    ]
  },
  "hooks": { ... }
}
```

## Cost knobs

Two env vars override defaults (set in your cron line or shell profile):

| Var                  | Default  | Notes                                                    |
|----------------------|----------|----------------------------------------------------------|
| `ORCH_WORKER_MODEL`  | `sonnet` | Set to `opus` for plans known to need stronger reasoning |
| `ORCH_MAX_TURNS`     | `30`     | Reviewer-block iterations × ~3 turns each                |
| `ORCH_LOG_MAX_BYTES` | `10485760` | Log rotation threshold (default 10 MiB)                |

## First run

```bash
# Drop a plan
cp my-plan.md .claude/plans/PLAN-01-my-feature.md

# Ingest it (generates state file + auto-merge overrides)
.claude/scripts/ingest-plan.sh .claude/plans/PLAN-01-my-feature.md

# Review the generated state file — confirm auto-merge overrides look right
cat .claude/plans/PLAN-01-my-feature.state.json

# Run one tick manually to test
./orchestrator.sh

# If that worked, schedule it
crontab -e
# Add: */5 * * * * cd /path/to/repo && ./orchestrator.sh >> .claude/state/orchestrator.log 2>&1
```

## What each tick does

1. Acquire lock (PID-aware; stale locks from crashed runs are auto-broken)
2. Find oldest in-progress plan state file
3. **Pending-PR gate:** if a previous tick recorded `pending_pr`, check its
   merge state. If MERGED, clear it and advance `current_task`. If still
   open, exit (don't start the next task off stale `main`). If CLOSED
   unmerged, mark plan blocked and notify.
4. Read current task number from state
5. Create worktree on branch `claude/plan-NN-task-M`
6. Spawn `claude -p` with the worker prompt + extracted task content
7. Worker implements the task; Stop hook runs reviewer; iterates if needed
8. On worker success: `git push`, then `gh pr create`
9. If auto-merge eligible: `gh pr merge --auto` and record `pending_pr` —
   next tick gates on its merge before continuing
10. If sensitive-flagged: label `needs-robbie`, notify, advance state
11. Remove worktree, release lock

State file fields:
- `current_task`, `total_tasks`, `retries_for_current`, `status`
- `auto_merge_overrides` — map of task number → `false` for sensitive tasks
- `pending_pr` — set when an auto-merge is in flight; cleared on next tick

## Files

```
CLAUDE.md                              — project conventions (root)
orchestrator.sh                        — the loop
.claude/
  defaults.md                          — when-in-doubt rules
  settings.json                        — hooks wiring
  prompts/
    worker-superpower.md               — autonomous worker prompt
    reviewer-system.md                 — pre-push reviewer prompt
  hooks/
    stop-pre-push-review.sh            — runs reviewer, blocks stop on fail
  scripts/
    ingest-plan.sh                     — plan → state file
    notify.sh                          — escalation notifications
  plans/
    PLAN-NN-slug.md                    — your plans
    PLAN-NN-slug.state.json            — current task, retries, auto-merge map
    archive/                           — completed plans
  state/
    decisions.md                       — append-only decision log
    run-<task>-r<retry>.json           — per-task-per-retry worker output (gitignored)
    orchestrator.lock/                 — lockdir (gitignored)
```

## Maintenance

The orchestrator leaves a worktree in place when a task fails so you can
inspect it. After 3 retries the plan blocks but the worktree stays. Add a
weekly prune cron alongside the main one:

```cron
# Main loop — every 5 minutes
*/5 * * * * cd /path/to/repo && ./orchestrator.sh >> .claude/state/orchestrator.log 2>&1

# Sidecar — prune abandoned worktrees on Sundays at 3am
0 3 * * 0 cd /path/to/repo && git worktree prune -v >> .claude/state/orchestrator.log 2>&1
```

Logs rotate at 10 MiB by default (override with `ORCH_LOG_MAX_BYTES`).
Rotated files are named `orchestrator.log.YYYYMMDDTHHMMSSZ`.

## Killing the loop

```bash
# Disable cron entry, then:
rm -rf .claude/state/orchestrator.lock                # lockdir now contains a pid file
# Or set status to blocked so any in-flight ticks abort cleanly:
jq '.status = "blocked"' .claude/plans/PLAN-01-*.state.json > /tmp/s && \
  mv /tmp/s .claude/plans/PLAN-01-*.state.json
```

## Resuming a blocked plan

After investigating and fixing whatever caused the block:

```bash
# If a stuck pending_pr is the cause (PR was closed without merge), clear it:
jq 'del(.pending_pr) | .status = "in_progress" | .retries_for_current = 0' \
  .claude/plans/PLAN-01-*.state.json > /tmp/s && \
  mv /tmp/s .claude/plans/PLAN-01-*.state.json

# Otherwise (worker hit retry limit):
jq '.status = "in_progress" | .retries_for_current = 0' \
  .claude/plans/PLAN-01-*.state.json > /tmp/s && \
  mv /tmp/s .claude/plans/PLAN-01-*.state.json
```
