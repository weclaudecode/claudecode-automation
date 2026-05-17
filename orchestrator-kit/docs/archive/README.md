# Claude Code Plan Orchestrator

Autonomous loop that executes superpower-style plans task-by-task with
pre-push review and conditional auto-merge.

## Prerequisites

- macOS or Linux
- `claude` CLI authenticated with your Max plan (`claude /login`)
- `gh` CLI authenticated (`gh auth login`)
- `jq`, `git`, `awk` (standard)
- A GitHub repo with `main` branch and branch protection allowing `--auto` merges
- Optional: cron / launchd for scheduled triggers

```bash
brew install gh jq          # macOS
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
EOF
```

Then customize:

1. Edit `CLAUDE.md` — your stack, conventions, must-rules
2. Edit `.claude/defaults.md` — your "when in doubt" rules
3. Optionally edit `.claude/state/decisions.md` to seed prior decisions

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

1. Acquire lock (one tick at a time, ever)
2. Find oldest in-progress plan state file
3. Read current task number from state
4. Create worktree on branch `claude/plan-NN-task-M`
5. Spawn `claude -p` with the worker prompt + plan + task assignment
6. Worker implements the task; Stop hook runs reviewer; iterates if needed
7. On worker success: `gh pr create`, then auto-merge or label `needs-robbie`
8. Advance state to next task; remove worktree
9. Release lock

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
    run-<task>.json                    — per-task worker output (gitignored)
    orchestrator.lock/                 — lockdir (gitignored)
```

## Killing the loop

```bash
# Disable cron entry, then:
rmdir .claude/state/orchestrator.lock 2>/dev/null  # if stuck
# Or set status to blocked:
jq '.status = "blocked"' .claude/plans/PLAN-01-*.state.json > /tmp/s && \
  mv /tmp/s .claude/plans/PLAN-01-*.state.json
```

## Resuming a blocked plan

After investigating and fixing whatever caused the block:

```bash
jq '.status = "in_progress" | .retries_for_current = 0' \
  .claude/plans/PLAN-01-*.state.json > /tmp/s && \
  mv /tmp/s .claude/plans/PLAN-01-*.state.json
```
