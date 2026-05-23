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

### Enable repo-level auto-merge (required)

`gh pr merge --auto` only works when the repo has `allow_auto_merge=true`.
Some `gh` versions accept `gh repo edit --enable-auto-merge` and exit 0
without actually flipping the flag, which leaves the orchestrator stuck on
every PR. Use the API directly and assert the result:

```bash
gh api "repos/<owner>/<repo>" -X PATCH -f allow_auto_merge=true \
  --jq '.allow_auto_merge' | grep -qx true \
  || { echo "allow_auto_merge did not enable" >&2; exit 1; }
```

After install, run `.claude/scripts/check-preconditions.sh` from the target
repo — it verifies branch protection, required checks, and
`allow_auto_merge` together and exits non-zero if any of them are off.

## Install into a repo

From your repo root:

```bash
# Copy this kit into the repo
cp -r /path/to/this/kit/.claude .
cp /path/to/this/kit/orchestrator.sh .
cp /path/to/this/kit/CLAUDE.md .   # only if you don't already have one — review carefully

# Also copy the canonical format spec — /plan-format and plan-author skill read it
mkdir -p .claude/docs
cp /path/to/this/kit/docs/PLAN-FORMAT.md .claude/docs/PLAN-FORMAT.md

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

## Authoring plans

Two helpers create or import plans in the strict
[`PLAN-FORMAT.md`](docs/PLAN-FORMAT.md) shape that `ingest-plan.sh`
accepts:

- **`/plan-format <input-path> [slug]`** — slash command. Converts a
  freeform plan markdown file into a valid `PLAN-NN-<slug>.md`,
  then runs `ingest-plan.sh` and iterates on validator errors. Use
  when you already have a plan written and want it formatted.
- **`plan-author` skill** — triggers on phrases like "design an
  orchestrator plan for X". Interactively walks goal →
  decomposition → dep/touches → emit + validate. Use when you're
  starting from a goal, not a draft.

Both write to `.claude/plans/`, do not clobber existing files, and
never commit on your behalf. See
[`SPEC-plan-authoring.md`](docs/SPEC-plan-authoring.md) for the full
design.

## Permissions model

Workers run with `--permission-mode bypassPermissions` — no prompts for
Bash, file edits, or network. This is intentional: workers are unattended
and stalling on a permission prompt would just trip `--max-turns`. Do not
add a `permissions.allow` block; under bypass it has no effect.

Safety comes from the layers around the worker, not from sandboxing it:

- **Reviewer phase** (`review-pr.sh`) blocks PRs that contain `safety_block`
  findings — IAM widenings, destructive migrations, secrets in diffs.
- **Sensitive tasks** flagged at ingest time land in `auto_merge_overrides`
  and skip `--auto`; merging requires a human.
- **Iter cap** (`ORCH_MAX_TURNS`, retry limit) halts runaway workers.

Run the orchestrator in a single repo with branch protection on `main`,
not in a multi-tenant or shared-credential environment.

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
3. **Sweep-merges pass:** transition any `in_review` task whose PR has merged
   to `merged`; mark plan-level blocked if a PR closed unmerged
4. **Find-ready pass:** pick tasks whose `depends_on` are all `merged` and
   whose `touches` don't collide with live `in_progress`/`in_review` siblings
5. **Launch pass:** create worktree on `claude/plan-NN-task-M`, spawn
   `claude -p` with the worker prompt + extracted task content, push, open PR,
   transition task to `in_review` (auto-merge eligible PRs get `gh pr merge --auto`)
6. **Review pass** (`review-pr.sh`): a fresh `claude -p` reviewer reads the PR
   diff and posts findings; `safety_block` findings keep the task in `in_review`
7. **Iterate pass** (`iterate-pr.sh`): for any `in_review` task with reviewer
   findings, spawn a worker against the existing branch to address them;
   hitting the iter cap transitions the task to `blocked`
8. The Stop hook only smoke-checks that the worker produced a diff vs `main` —
   it no longer drives review
9. Release lock

State file (v2 schema; `ingest-plan.sh` is the canonical source):
- Top-level: `plan_file`, `total_tasks`, `status` (`in_progress` | `done` | `blocked`),
  `auto_merge_overrides` (`{ "<task>": false }`), `auto_recommended`, `ingested_at`
- Per-task under `tasks["<n>"]`: `title`, `depends_on`, `touches`, `issue`, `pr`,
  `status`, `retries`, `max_turns`, and on block `blocked_at` + `blocked_reason`
  (`worker_failed_3x` | `iterate_failed_3x` | `review_iter_cap` | `pr_closed_unmerged`
  | `upstream_blocked_t<N>`); on merge `merged_at`
- Per-task FSM: `pending → in_progress → in_review → merged` (any state → `blocked`)

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
# Plan-level: flip back to in_progress so ticks resume
jq '.status = "in_progress"' \
  .claude/plans/PLAN-01-*.state.json > /tmp/s && \
  mv /tmp/s .claude/plans/PLAN-01-*.state.json

# Reset a single blocked task (e.g. task 3) back to pending
jq '.tasks["3"].status = "pending"
    | .tasks["3"].retries = 0
    | del(.tasks["3"].blocked_at, .tasks["3"].blocked_reason)' \
  .claude/plans/PLAN-01-*.state.json > /tmp/s && \
  mv /tmp/s .claude/plans/PLAN-01-*.state.json

# Clear cascade blocks (tasks blocked only because an upstream was blocked)
jq '.tasks |= with_entries(
      if (.value.blocked_reason // "") | startswith("upstream_blocked_")
      then .value.status = "pending"
           | .value.retries = 0
           | .value |= (del(.blocked_at, .blocked_reason))
      else . end)' \
  .claude/plans/PLAN-01-*.state.json > /tmp/s && \
  mv /tmp/s .claude/plans/PLAN-01-*.state.json
```
