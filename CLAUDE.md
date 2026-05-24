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

The canonical kit lives under `orchestrator-kit/`. Earlier drafts of the
same scripts have been archived to `orchestrator-kit/docs/archive/` for
historical reference — do not edit them; treat them as a frozen snapshot
of the pre-fix-plan state. Use `git log --follow orchestrator-kit/docs/archive/<file>`
to walk back through pre-archive history.

`orchestrator-kit/CLAUDE.md` is a **template that the installer copies into the target repo**. It describes a downstream stack (Python/TS/AWS/Bedrock) that does not apply to this repo. Don't read it as guidance for work here.

## Test target repo

End-to-end testing of the orchestrator happens against a separate sacrificial repo: `weclaudecode/claudecode-test-target` (cloned locally at `/Users/rb/Documents/Github/claudecode-test-target`). That repo's README lists a backlog of task ideas; the test plans we author against it live in its `.claude/plans/` once the kit is installed into it.

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

`orchestrator.sh` is a single-shot tick (cron or `/loop` invokes it). It is **idempotent and self-terminating**: every tick walks a fixed sequence of phases against the active plan's state file, then exits. State lives entirely on disk under `.claude/`. Per-task transitions happen inside phases, not at the tick level.

```
                  cron / loop / manual
                          │
                          ▼
              ┌──────────────────────┐
              │  orchestrator.sh     │
              │  (one tick)          │
              └──────────┬───────────┘
                         │
   Phase 0: acquire lock (mkdir + PID liveness; break stale)
            mop up leaked worktrees from any prior killed tick
            pick newest in_progress *.state.json (else idle)
                         │
   Phase 1: refresh-deps.sh
            for each pending task whose depends_on are all merged,
            add orch:deps-met to its dep-issue (signals readiness)
                         │
   Phase 2: sweep-merges.sh
            for each task in_review with a .pr set:
              MERGED  → tasks.N.status = merged, close issue,
                        fork post-merge-check.sh (CI watcher, disowned)
              CLOSED  → tasks.N.status = blocked, label safety-block,
                        cascade_block transitive pending dependents
              OPEN    → no-op (handed off to review-pass)
                         │
   Phase 2.5: retry-auto-merge.sh   (optional — only if executable)
            for each in_review task whose PR has orch:needs-robbie
            (and not orch:safety-block, and auto_merge_overrides[N] != false):
            retry `gh pr merge --auto --squash --delete-branch`;
            on success strip orch:needs-robbie, on failure leave labelled
                         │
   Phase 3: review-pass.sh   (optional — only if executable)
            for each in_review PR: rebase if CONFLICTING/BEHIND;
            CI red → post synthetic blocker (orch:ci-gate-sha marker);
            CI pending → defer; else if HEAD SHA != orch:review-sha,
            spawn review-pr.sh in background (claude -p; SKIP_REVIEW=1)
                         │
   Phase 4: iterate-pass.sh  (optional — only if executable)
            for each in_review PR with orch:review-blocked AND
            (review-sha OR ci-gate-sha == HEAD): spawn iterate-pr.sh
                         │
   Phase 5: launch-pass.sh
            SLOTS = MAX_PARALLEL - count(in_review);
            find-ready-tasks.sh emits up to SLOTS ready task numbers
            (pending + deps merged + no touches-glob collision with
            in-flight tasks); spawn launch-worker.sh per task in
            background; wait on all PIDs
                         │
   each launch-worker.sh:
     git worktree add -B claude/plan-NN-task-M ../wt-planNN-tM origin/main
     register_worktree → claude -p (bypassPermissions, JSON) → push →
     gh pr create → tasks.N.{pr,status:in_review} → unregister_worktree
                         │
   Plan-completion check
     all tasks terminal (merged | blocked)? → mark done or blocked,
     archive plan + state file, notify
                         │
   Phase 6: plan-status.sh (dashboard refresh, best-effort)
                         │
   Phase 7: monitor-sweep.sh   (optional — only if ORCH_MONITOR_ENABLED=1)
            sources each _heuristics/*.sh in glob order; each heuristic
            calls monitor_finding when a pattern fires; findings are
            hash-dedup'd and filed as GH Issues labelled monitor:finding
                         │
   release lock (trap also runs cleanup_active_worktrees)
```

### Key invariants

- **One tick at a time, ever.** Lock is a directory containing a PID file. Stale locks (PID dead) are auto-broken; live ones cause the tick to no-op. The EXIT/INT/TERM trap also runs `cleanup_active_worktrees` so a killed tick doesn't leak `wt-planNN-tM/` directories.
- **Each task gets a fresh `claude -p` context.** No `--resume`. The plan + extracted task spec are re-sent every spawn. Decisions persist via `.claude/state/decisions.md`, not session memory.
- **All state.json writes go through `state_write` in `_dispatcher_lib.sh`.** Per-state-file mkdir lockdir (`<state>.lock.d`) with stale-PID break. Required because multiple workers, sweep/review/iterate phases, and the tick itself can all touch the same file concurrently when `MAX_PARALLEL > 1`.
- **Tasks transition through a fixed FSM:** `pending → in_progress → in_review → merged` (happy path), with `blocked` reachable from any non-terminal status. Only `merged` and `blocked` are terminal; the plan-completion check archives when all tasks reach one of those.
- **`find-ready-tasks.sh` enforces touches-collision exclusion** via Python `glob.glob(recursive=True)` against the worktree file list: a pending task whose touches expand to any path also touched by an `in_progress`/`in_review` task is held back. This is the only protection against two concurrent workers editing the same files; do not bypass it.
- **A blocked task cascade-blocks its transitive pending dependents.** `cascade_block` in `_dispatcher_lib.sh` walks the reverse depends_on graph and writes `blocked_reason: upstream_blocked_t<N>` on every pending downstream. Without it, downstream tasks whose dep-issue never closes loop forever and the plan never archives. Cascade only touches `pending` tasks — never preempts a live worker's `in_progress`/`in_review` row.
- **Sensitive-flagged tasks (`auto_merge_overrides[N] == false`) get `orch:needs-robbie` and stay in `in_review`** until the operator merges by hand; sweep-merges then transitions them like any other PR.
- **The reviewer never re-triggers the Stop hook.** Reviewers and iterators now run in their own `claude -p` calls from `review-pr.sh`/`iterate-pr.sh` (spawned by the phase scripts), not from the Stop hook. The hook's `SKIP_REVIEW=1` fence is still set on those spawns as belt-and-braces against future reintroduction of hook-driven review.
- **Monitor findings are append-only; they never modify plan state, only file issues for operator attention.** Dedup is hash-based and re-fires after 7 days if the issue is closed without the underlying pattern clearing. Disable with `ORCH_MONITOR_ENABLED=0`; tune per-heuristic thresholds via `ORCH_MONITOR_H*` env vars (see `orchestrator-kit/README.md`).

## State files at a glance

`.claude/plans/PLAN-NN-slug.state.json` is the canonical plan record. Schema v2 (the only schema the kit reads or writes):

```json
{
  "plan_file": ".claude/plans/PLAN-01-foo.md",
  "total_tasks": 7,
  "status": "in_progress",            // in_progress | done | blocked
  "tasks": {
    "1": {
      "title": "...",
      "depends_on": [],                // task numbers this one waits on
      "touches": ["path/**", "..."],   // gitignore-syntax globs
      "issue": 41,                     // null until refresh-deps opens it
      "pr": 142,                       // null until launch-worker pushes
      "status": "pending",             // pending | in_progress | in_review | merged | blocked
      "retries": 0,                    // bumped by iterate-pass on re-runs
      "max_turns": null,               // override claude -p --max-turns
      "blocked_at": "<iso8601>",       // set when status -> blocked
      "blocked_reason": "worker_failed_3x" // | review_iter_cap | pr_closed_unmerged | upstream_blocked_t<N>
      // "merged_at": "<iso8601>" set when status -> merged
    }
  },
  "auto_merge_overrides": {"5": false}, // task → false to disable auto-merge (sensitive flag)
  "auto_recommended": false,            // per-plan override of ORCH_AUTO_RECOMMENDED
  "ingested_at": "<iso8601>"
}
```

Plan-level `status: blocked` only appears at archive time when no tasks merged (see `orchestrator.sh` completion check). A task with `status: blocked` halts only its own dependency subtree; the rest of the plan continues. Three consecutive worker failures on the same task auto-block it (`blocked_reason: worker_failed_3x`, worktree preserved for inspection).

## Hard dependencies (will silently break things if missing)

- **`gawk`** (GNU awk), not BSD awk. `ingest-plan.sh` uses `match($0, regex, array)` which BSD awk silently no-ops, causing **every plan to ingest with empty `auto_merge_overrides` so IAM/migration tasks auto-merge**. The current `orchestrator-kit/.claude/scripts/ingest-plan.sh` enforces this via `command -v gawk`; the root-level draft does not. On macOS: `brew install gawk`.
- **`PyYAML`** (Python package) — required since PLAN-05. `ingest-plan.sh`
  uses `python3 -c 'import yaml'` to parse the `---` YAML frontmatter of
  plan files (the new `aws:`, `env:`, `requires:`, `pre_flight:` keys).
  Without PyYAML, ingest fails with `ModuleNotFoundError`. Install via
  `pip install pyyaml` (system pip or whichever python3 the kit uses).
- **`pr-review-toolkit` plugin** in the target repo. `review-pr.sh` runs as a multi-agent coordinator (see `orchestrator-kit/.claude/prompts/reviewer-system.md`) that dispatches `pr-review-toolkit:code-reviewer`, `silent-failure-hunter`, `comment-analyzer`, `pr-test-analyzer`, `type-design-analyzer`, plus the built-in `/security-review` skill, in parallel. Without the plugin, the coordinator's Task calls return "Unknown subagent type" and the reviewer **degrades to an inline single-agent review** (still produces a JSON verdict so the merge gate keeps working, but loses the multi-perspective signal and the security pass). Install in each target repo with `claude plugin install pr-review-toolkit`. Worker and iterator prompts also reference `superpowers:verification-before-completion`, `superpowers:test-driven-development`, `superpowers:systematic-debugging`, `superpowers:receiving-code-review`, and the `context7` MCP — same degradation policy: noted in `decisions.md` and skipped if not present.
- `jq`, `gh`, `git`, `claude` CLI. The orchestrator assumes `gh auth status` works and `claude /login` has been done with a Max plan.
- The reviewer Stop hook depends on `claude -p` being callable from inside a hook. Settings file at `.claude/settings.json` wires it.

## Editing conventions specific to this kit

- All disk paths in shell scripts are relative to `$(git rev-parse --show-toplevel)`, established at the top of each script. Don't introduce `pwd`-relative paths — the orchestrator `cd`s into worktrees mid-tick.
- Hooks must **never block on infrastructure failures** (claude API down, network, missing files). They should `exit 0` with a note on stderr. Only `exit 2` for genuine review blockers. The existing hooks model this — preserve the pattern.
- When changing the per-tick log shape, remember consumers parse it with `grep`/`tail` from cron mail. Keep one-line-per-event semantics.
- Plan/task parsing is **fence-aware**: `## Task N:` inside a fenced code block must NOT count as a section header. Both `ingest-plan.sh` and `stop-pre-push-review.sh` in `orchestrator-kit/` handle this; the root drafts do not. Any new awk that walks plan files must too.
- The worker prompt's decision tiers (Tier 1 silent / Tier 2 log / Tier 3 escalate) are load-bearing safety policy. Don't soften them without checking `orchestrator-kit/docs/FIX-PLAN.md` first.
