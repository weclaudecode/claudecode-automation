# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **template/source** for the Claude Code Plan Orchestrator — a Bash kit that
gets copied into a *target* git repo and there drives an autonomous loop of
`claude -p` workers, one per task of a superpower-style implementation plan,
with pre-push code review and conditional auto-merge.

This directory is **not itself a git repo and is not meant to be executed in
place**. The orchestrator only makes sense inside a target repo with `main`,
branch protection, and `gh` auth. To exercise it, follow the install
instructions in `orchestrator-kit/README.md` against a separate test repo.

## Source-of-truth layout (read this before editing)

Two parallel copies of the same toolkit live here:

| Path | Status |
|---|---|
| `orchestrator-kit/` | **Canonical, current.** All fixes from `orchestrator-kit/docs/FIX-PLAN.md` land here. |
| `./orchestrator.sh`, `./ingest-plan.sh`, `./stop-pre-push-review.sh`, `./worker-superpower.md`, `./README.md` | Earlier drafts. Missing pending-PR gate, PID-aware locking, log rotation, fence-aware task parsing, `gawk` enforcement, and `pending_pr` state field. |

**When editing scripts or prompts, edit the version under `orchestrator-kit/` and treat the root-level loose files as historical** unless the user explicitly asks to sync them. Before changing the root copies, ask whether they should be deleted or kept as a snapshot.

`orchestrator-kit/CLAUDE.md` is a **template that the installer copies into the target repo**. It describes a downstream stack (Python/TS/AWS/Bedrock) that does not apply to this repo. Don't read it as guidance for work here.

## Common commands

There is no build, lint, or test suite in this repo — it's pure shell + markdown.

| Task | Command |
|---|---|
| Sanity-check a shell script | `shellcheck orchestrator-kit/orchestrator.sh orchestrator-kit/.claude/hooks/*.sh orchestrator-kit/.claude/scripts/*.sh` |
| Make scripts executable after editing | `chmod +x orchestrator-kit/orchestrator.sh orchestrator-kit/.claude/hooks/*.sh orchestrator-kit/.claude/scripts/*.sh` |
| Dry-run plan ingestion against a fixture | `cd /tmp && mkdir t && cd t && /path/to/orchestrator-kit/.claude/scripts/ingest-plan.sh some-plan.md` |
| Install kit into a target repo | See `orchestrator-kit/README.md` ("Install into a repo") |

The phase 0 reproduction steps in `orchestrator-kit/docs/FIX-PLAN.md` are the closest thing this repo has to a regression test — useful when changing `ingest-plan.sh`, locking, or PR-merge gating logic.

## Architecture: one orchestrator tick

`orchestrator.sh` is a single-shot tick (cron or `/loop` invokes it). It is **idempotent and self-terminating**: every tick either advances state by exactly one task, waits, or no-ops. State lives entirely on disk under `.claude/`.

```
                  cron / loop / manual
                          │
                          ▼
              ┌──────────────────────┐
              │  orchestrator.sh     │
              │  (one tick)          │
              └──────────┬───────────┘
                         │
   acquire lock (mkdir + PID liveness check; break stale)
                         │
   find oldest in_progress *.state.json
                         │
   pending_pr gate ────► MERGED?  → clear, advance current_task
                         │         CLOSED unmerged? → mark blocked, notify
                         │         else → exit (don't branch off stale main)
                         │
   extract current task from PLAN-NN-*.md (fence-aware awk)
                         │
   git worktree add -B claude/plan-NN-task-M ../wt-planNN-tM origin/main
                         │
   claude -p WORKER_PROMPT --permission-mode acceptEdits --output-format json
                         │
                  (Stop hook fires)
                         │
              ┌──────────────────────┐
              │ stop-pre-push-       │
              │ review.sh            │
              │  → spawns sonnet     │
              │    reviewer in fresh │
              │    claude -p         │
              └──────────┬───────────┘
                         │
            pass: true  →  exit 0 (worker stops)
            pass: false + blockers → exit 2 (worker iterates)
                         │
   worker exit 0 → git push → gh pr create
                         │
            auto-merge eligible? → gh pr merge --auto, record pending_pr
                                   (next tick gates on its merge)
            sensitive-flagged?  → label needs-robbie, notify, advance now
                         │
   release lock
```

### Key invariants

- **One tick at a time, ever.** Lock is a directory containing a PID file. Stale locks (PID dead) are auto-broken; live ones cause the tick to no-op.
- **Each task gets a fresh `claude -p` context.** No `--resume`. The plan + extracted task spec are re-sent every tick. Decisions persist via `.claude/state/decisions.md`, not session memory.
- **Auto-merged tasks block subsequent ticks until merged.** When `gh pr merge --auto` is enabled, the tick writes `pending_pr: <PR#>` and exits without advancing. The next tick checks `gh pr view <PR#> --json state` before doing anything else. This prevents task N+1 from branching off stale `main` while task N is still merging.
- **Sensitive-flagged tasks advance state immediately** (no `pending_pr`) because the operator merges them manually and subsequent tasks shouldn't wait on human review latency.
- **The reviewer's own Stop event must not retrigger the hook.** `stop-pre-push-review.sh` sets `SKIP_REVIEW=1` before spawning the reviewer's `claude -p`. Don't remove this fence.

## State files at a glance

`.claude/plans/PLAN-NN-slug.state.json` is the canonical task pointer:

```json
{
  "plan_file": ".claude/plans/PLAN-01-foo.md",
  "current_task": 3,
  "total_tasks": 7,
  "retries_for_current": 0,
  "status": "in_progress",            // in_progress | blocked | done
  "auto_merge_overrides": {"5": false},  // task → false to disable auto-merge
  "pending_pr": 142                    // present iff an --auto merge is in flight
}
```

`status: blocked` halts the loop until manually edited back to `in_progress`. Three consecutive worker failures auto-block (worktree preserved for inspection). `pending_pr` closed unmerged also auto-blocks.

## Hard dependencies (will silently break things if missing)

- **`gawk`** (GNU awk), not BSD awk. `ingest-plan.sh` uses `match($0, regex, array)` which BSD awk silently no-ops, causing **every plan to ingest with empty `auto_merge_overrides` so IAM/migration tasks auto-merge**. The current `orchestrator-kit/.claude/scripts/ingest-plan.sh` enforces this via `command -v gawk`; the root-level draft does not. On macOS: `brew install gawk`.
- `jq`, `gh`, `git`, `claude` CLI. The orchestrator assumes `gh auth status` works and `claude /login` has been done with a Max plan.
- The reviewer Stop hook depends on `claude -p` being callable from inside a hook. Settings file at `.claude/settings.json` wires it.

## Editing conventions specific to this kit

- All disk paths in shell scripts are relative to `$(git rev-parse --show-toplevel)`, established at the top of each script. Don't introduce `pwd`-relative paths — the orchestrator `cd`s into worktrees mid-tick.
- Hooks must **never block on infrastructure failures** (claude API down, network, missing files). They should `exit 0` with a note on stderr. Only `exit 2` for genuine review blockers. The existing hooks model this — preserve the pattern.
- When changing the per-tick log shape, remember consumers parse it with `grep`/`tail` from cron mail. Keep one-line-per-event semantics.
- Plan/task parsing is **fence-aware**: `## Task N:` inside a fenced code block must NOT count as a section header. Both `ingest-plan.sh` and `stop-pre-push-review.sh` in `orchestrator-kit/` handle this; the root drafts do not. Any new awk that walks plan files must too.
- The worker prompt's decision tiers (Tier 1 silent / Tier 2 log / Tier 3 escalate) are load-bearing safety policy. Don't soften them without checking `orchestrator-kit/docs/FIX-PLAN.md` first.
