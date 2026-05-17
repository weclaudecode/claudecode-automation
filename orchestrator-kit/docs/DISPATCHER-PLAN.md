# Dispatcher Sub-plan — Phase 2 Task 2.3

Detailed plan for the priority-dispatcher refactor of `orchestrator.sh`,
the single largest change in the SDLC evolution. Sequenced as 7 sub-tasks
(A-G) shippable independently, each with verification.

> The current `orchestrator.sh` is a single-task sequential tick: lock,
> find one task, spawn one worker, push PR, release lock. The new model
> is a 5-phase tick that handles refresh / merge-sweep / review / iterate
> / launch in priority order, with up to `MAX_PARALLEL` workers running
> in parallel within a single tick.

## Decisions baked in

| Decision | Choice | Why |
|---|---|---|
| Tick concurrency model | Synchronous, one tick at a time (global lock preserved) | Avoids state.json concurrent-writer bugs; matches current lock pattern |
| In-tick worker parallelism | Up to `MAX_PARALLEL`, `&` + `wait` | Simple shell primitives; no mailbox/consolidation pass needed |
| `MAX_PARALLEL` default | `1` | Preserves current sequential behavior on upgrade; opt in via env var |
| State.json writes | Only main tick process writes; atomic via temp+mv | Single writer; no locks beyond the global tick lock |
| Worker output contract | Existing JSON-to-stdout (per worker-superpower.md) | No change needed; tick parses the JSON |
| Worktree lifecycle | Create at launch, remove after worker exits | Iterate workers re-create from branch as needed; no stale-worktree risk |
| Backward compat with old state.json | None — Phase 1 ships the v2 schema, dispatcher consumes v2 only | Already accepted in SDLC plan rollout |

## Tick flow (the 5 phases)

```
                       cron / loop
                            │
                            ▼
                  acquire global lock (PID-aware)
                            │
                            ▼
              find oldest in_progress plan state.json
                            │
              ┌──────────────────────┐
              │ Phase 1: refresh     │  refresh-deps.sh
              │          deps        │  adds orch:deps-met where ready
              └──────────┬───────────┘
                            │
              ┌──────────────────────┐
              │ Phase 2: pending     │  check tasks with .pr set;
              │     merge sweep      │  transition merged → CLOSED unmerged → blocked
              └──────────┬───────────┘
                            │
              ┌──────────────────────┐
              │ Phase 3: review      │  for in_review tasks with new commits
              │          pass        │  since last review, spawn review-pr.sh
              │                      │  (parallel, wait)
              └──────────┬───────────┘
                            │
              ┌──────────────────────┐
              │ Phase 4: iterate     │  for tasks with orch:review-blocked +
              │          pass        │  reviewer comment newer than last commit,
              │                      │  spawn iterate worker (parallel, wait)
              └──────────┬───────────┘
                            │
              ┌──────────────────────┐
              │ Phase 5: launch      │  find up to (MAX_PARALLEL -
              │          pass        │  currently_in_review) ready tasks;
              │                      │  spawn new workers (parallel, wait)
              └──────────┬───────────┘
                            │
                  check if all tasks merged
                  → archive plan, notify
                            │
                       release lock
```

Each phase reads state, may write state. Phases are sequential within a
tick; parallelism is **within** a phase (multiple workers in phases 3-5).

## State machine

Per-task statuses in `state.tasks.N.status`:

| State | Meaning |
|---|---|
| `pending` | Waiting in queue. May or may not be deps-met yet. |
| `in_review` | PR is open. Either awaiting first review, awaiting iteration, or about-to-merge. |
| `merged` | PR auto-merged successfully. Task complete. |
| `blocked` | Needs human. Reasons: 3 worker failures, reviewer iteration cap hit, PR closed unmerged, safety-block found. |

(The `working` transient state isn't represented — within a tick, a task
moves directly from `pending` to its post-spawn state.)

### Transition reference

| From | Trigger | To | Phase responsible |
|---|---|---|---|
| `pending` | Launch pass: worker succeeds, PR opened | `in_review` (sets `.pr`) | 5 |
| `pending` | Launch pass: worker fails, retries < 3 | `pending` (retries++) | 5 |
| `pending` | Launch pass: worker fails, retries == 3 | `blocked` | 5 |
| `in_review` | PR auto-merged | `merged` | 2 |
| `in_review` | PR closed without merge | `blocked` | 2 |
| `in_review` | Reviewer requests changes, iterate worker succeeds | `in_review` (iter++) | 3 + 4 |
| `in_review` | Reviewer iteration cap hit | `blocked` | 4 |
| `in_review` | Reviewer found safety_block class | `blocked` | 3 |

## File structure (post-rewrite)

`orchestrator-kit/orchestrator.sh` becomes a thin dispatcher that sources
helper functions. The main file shrinks to ~120 lines of orchestration;
phase logic lives in dedicated files for testability.

```
orchestrator-kit/
├── orchestrator.sh                          (main tick — top-level flow)
└── .claude/scripts/
    ├── _dispatcher_lib.sh                   (sourced helpers: lock, state I/O)
    ├── refresh-deps.sh                      (Phase 1 — done in Phase 1.4)
    ├── sweep-merges.sh                      (Phase 2 — NEW in 2.3.B)
    ├── review-pr.sh                         (Phase 3 — done in Task 2.2)
    ├── iterate-pr.sh                        (Phase 4 — NEW in 2.3.D)
    └── launch-worker.sh                     (Phase 5 — extracted in 2.3.A)
```

Each phase script accepts the state file path as its first arg and the
plan's state.json is the single source of truth they all read/write.

## Sub-task breakdown

### Dependency graph

```
Task 2.1 (Stop hook)        independent
Task 2.2 (review-pr.sh)     independent
   └────────────────────┐
                        ▼
2.3.A (extract worker)  ─►  2.3.B (merge sweep)  ─►  2.3.E (launch refactor)
                                                            │
                                                            ▼
                                                       2.3.F (wire tick)
                                                            │
            ┌───────────────────────────────────────────────┘
            ▼
2.3.C (review pass)  needs 2.2 + 2.3.F shipped
2.3.D (iterate pass)  needs 2.3.C
2.3.G (hardening)    needs 2.3.F
```

### Sub-task 2.3.A — Extract `launch_worker` function (low risk)

**Files:** `orchestrator-kit/.claude/scripts/launch-worker.sh` (new),
`orchestrator-kit/orchestrator.sh` (refactor — no behavior change yet)

Move the existing per-task body (worktree create → claude -p spawn → PR
create → state update) out of `orchestrator.sh` and into a standalone
`launch-worker.sh` that takes (state_file, task_num) as args.

Existing single-task logic continues to work; the old tick still calls
launch-worker.sh exactly once. This is pure refactoring.

**Verification:** ingest PLAN-SMOKE on test-target; run the orchestrator
tick manually with `ORCH_MAX_PARALLEL` unset (defaults to 1, same as
old); confirm one PR opens just as it does today.

### Sub-task 2.3.B — Pending-merge sweep phase

**Files:** `orchestrator-kit/.claude/scripts/sweep-merges.sh` (new)

New script. For each task in state.tasks.* with `.pr` set:
1. `gh pr view <pr> --json state,mergedAt,mergeCommit -q .state`
2. If `MERGED`: set `tasks.N.status = "merged"`, close issue (`gh issue close <issue>`)
3. If `CLOSED` (and not merged): set `tasks.N.status = "blocked"`,
   notify, label `orch:safety-block`
4. If `OPEN`: no-op (leave for later phases)

State.json updates are atomic via temp file + `mv`.

**Verification:** with PLAN-SMOKE issues live on test-target, manually
close one as completed (`gh issue close 1 --reason completed`) plus
create a fake PR + auto-merge it; run `sweep-merges.sh`; confirm
status transitions and issue closures.

### Sub-task 2.3.C — Review pass phase

**Depends on:** Task 2.2 (review-pr.sh) shipped first

**Files:** `orchestrator-kit/.claude/scripts/review-pass.sh` (new),
`orchestrator-kit/.claude/scripts/review-pr.sh` (extended with SHA marker)

For each task with status=in_review:
1. Read PR body, extract `<!-- orch:review-sha:<hash> -->` marker (the
   SHA that was last reviewed).
2. Fetch PR's current HEAD SHA: `gh pr view <pr> --json headRefOid`.
3. If HEAD SHA differs from recorded review-sha (or no marker exists):
   → spawn `review-pr.sh <pr>` in background.
4. After all spawned reviewers complete (`wait`): proceed to next phase.

Multiple reviewers run in parallel; up to `MAX_PARALLEL_REVIEWS`
(default = MAX_PARALLEL).

Requires `review-pr.sh` to update the PR body with the new
`orch:review-sha` marker after each review (extending the existing
`orch:review-iter:N` marker pattern from Task 2.2).

**Verification:** create a new commit on an `in_review` PR; run tick's
review pass; confirm review-pr.sh runs and updates the SHA marker.

### Sub-task 2.3.D — Iterate pass phase

**Depends on:** 2.3.C shipped first

**Files:** `orchestrator-kit/.claude/scripts/iterate-pr.sh` (new),
`orchestrator-kit/.claude/scripts/iterate-pass.sh` (new)

For each task with status=in_review AND PR has `orch:review-blocked`
label:
1. Check iteration count from `<!-- orch:review-iter:N -->`. If
   `N >= ORCH_REVIEW_MAX_ITERS` (default 3) → set status=blocked, add
   `orch:safety-block` label, notify.
2. Otherwise, re-create worktree from PR's branch (`git worktree add
   -B <branch> <wt> origin/<branch>`).
3. Spawn `claude -p` with iteration prompt:
   - Reads reviewer's change-request comments via `gh pr review list`
     and `gh api .../comments`
   - Addresses them, commits, pushes
4. After worker completes, remove the worktree. The next tick's review
   pass will re-review the new commits.

Iterate workers run in parallel up to `MAX_PARALLEL`.

**Verification:** post a `request-changes` review on a PR via `gh pr
review --request-changes`; run tick; confirm worker spawns in worktree,
addresses comments, pushes new commit.

### Sub-task 2.3.E — Launch pass refactor

**Files:** `orchestrator-kit/orchestrator.sh` (launch logic),
`orchestrator-kit/.claude/scripts/find-ready-tasks.sh` (interim version)

Replace the old single-task launch logic with a loop bounded by
`MAX_PARALLEL`:

```bash
IN_REVIEW_COUNT=$(jq '[.tasks[] | select(.status == "in_review")] | length' "$STATE_FILE")
SLOTS=$((MAX_PARALLEL - IN_REVIEW_COUNT))
[ "$SLOTS" -le 0 ] && { echo "no launch slots available"; return; }

READY=$(find-ready-tasks.sh "$STATE_FILE" "$SLOTS")
for task_num in $READY; do
  launch-worker.sh "$STATE_FILE" "$task_num" &
  WORKER_PIDS+=($!)
done
wait "${WORKER_PIDS[@]}"
```

Interim `find-ready-tasks.sh`: emit pending tasks with `orch:deps-met`,
up to N. The Phase 4 version adds `touches:` collision detection. Until
then, MAX_PARALLEL=1 is the safe default (no collision risk with 1
worker).

Each `launch-worker.sh` invocation handles its own state.json update
under a per-task write lock (very short — only the few jq operations
that update `tasks.N.status`, `.pr`, `.retries`).

**Verification:** with PLAN-SMOKE state, set MAX_PARALLEL=2; run tick;
confirm 2 workers launch in parallel (visible in process list or via
worktree creation timestamps).

### Sub-task 2.3.F — Wire phases together as the main tick

**Files:** `orchestrator-kit/orchestrator.sh` (top-level)

Replace existing tick body with the 5-phase sequence. Each phase
delegates to its script and ignores plan-completion until end-of-tick:

```bash
# Acquire lock, find STATE_FILE (same as today)
...

# Phase 1
.claude/scripts/refresh-deps.sh "$STATE_FILE" "$REPO_OWNER_REPO"

# Phase 2
.claude/scripts/sweep-merges.sh "$STATE_FILE" "$REPO_OWNER_REPO"

# Phase 3 (only if review-pr.sh exists — guard for incremental rollout)
[ -x .claude/scripts/review-pass.sh ] && \
  .claude/scripts/review-pass.sh "$STATE_FILE" "$REPO_OWNER_REPO"

# Phase 4
[ -x .claude/scripts/iterate-pass.sh ] && \
  .claude/scripts/iterate-pass.sh "$STATE_FILE" "$REPO_OWNER_REPO"

# Phase 5
.claude/scripts/launch-pass.sh "$STATE_FILE" "$REPO_OWNER_REPO" "$MAX_PARALLEL"

# Plan completion check
ALL_MERGED=$(jq '[.tasks[] | select(.status != "merged" and .status != "blocked")] | length == 0' "$STATE_FILE")
if [ "$ALL_MERGED" = "true" ]; then
  archive_plan "$STATE_FILE"
fi

echo "tick done"
```

The `[ -x ... ]` guards let early sub-tasks ship before C/D are done —
the tick gracefully skips missing phases.

**Verification:** with only A/B/E/F shipped (no C/D yet), run a full
tick against PLAN-SMOKE. Should advance one task per tick, same as
today's behavior. Add C/D, re-test, observe review/iterate phases
running.

### Sub-task 2.3.G — Concurrency / safety hardening

**Files:** various

After the dispatcher works end-to-end, layer in:

1. **Atomic state.json writes everywhere.** All updates use temp file +
   `mv`. Add a helper `state_write()` to `_dispatcher_lib.sh`.
2. **Worker timeout.** Wrap `claude -p` invocations with `timeout
   ${ORCH_WORKER_TIMEOUT:-600}s` (10 min default). Treat timeout as a
   worker failure (counts toward retries).
3. **Cleanup on tick interruption.** Trap `EXIT`/`INT`/`TERM` in
   orchestrator.sh; on exit, attempt to `git worktree remove --force`
   all worktrees created in this tick. Workers that were mid-spawn get
   their state advanced no further.
4. **Lock break tolerance.** Existing PID-aware lock works; extend to
   handle the case where a tick was killed but worktrees survived.
   Already present in current code; verify it still works post-refactor.

**Verification:** kill an orchestrator tick mid-launch (SIGTERM); run
next tick; confirm cleanup happened and state is consistent.

## Worker output contract

The dispatcher consumes the JSON `claude -p --output-format json`
emits. The worker-superpower.md prompt requires the final message to be:

```json
{
  "task": <task_number>,
  "status": "complete" | "blocked",
  "summary": "<PR description>",
  "decisions_made": ["..."],
  "files_changed": ["..."],
  "tests_run": "<command>",
  "tests_result": "pass" | "fail",
  "followup_issues_filed": [...]
}
```

Dispatcher reads:
- `status` — determines task transition
- `summary` — becomes PR description
- `files_changed` — logged for debugging only (Phase 4 may add
  enforcement: changed files must ⊆ touches: globs)

When status is `blocked`, dispatcher reads `block_reason` (added by
worker-superpower.md), labels the related issue `orch:safety-block`,
notifies.

## Testing strategy

Each sub-task ships with a verification step (above). End-to-end test
after all sub-tasks land:

1. Ensure PLAN-SMOKE issues are in post-ingest state on test-target.
2. Run a full tick with `ORCH_MAX_PARALLEL=1` against a worktree of
   test-target. Expected:
   - Tick 1: launches task 1 (no deps, deps-met)
   - Worker creates PR, CI runs, auto-merges
   - Tick 2: sweep detects merge, advances task 1 to merged; refresh
     adds deps-met to task 3; launches task 2 (first deps-met pending)
3. Run a tick with `ORCH_MAX_PARALLEL=2`. Expected:
   - Tick 1: launches tasks 1 and 2 in parallel
   - Their PRs both open, CI runs concurrently
4. Force a reviewer change-request scenario. Expected:
   - Review pass adds change-request comments to PR
   - Next tick's iterate pass spawns a worker, addresses comments
   - Following tick's review pass reviews the new commits

## Rollout sequence

Within Phase 2 of the SDLC plan:

1. **2.1** — Strip Stop hook (independent, ships first)
2. **2.2** — review-pr.sh (independent, ships second)
3. **2.3.A** — Extract launch-worker.sh
4. **2.3.B** — sweep-merges.sh
5. **2.3.E** — Launch pass refactor
6. **2.3.F** — Wire tick (now end-to-end, but C/D phases are no-ops)
7. **2.3.G (partial)** — Atomic state writes + worker timeout
8. **2.3.C** — review-pass.sh (requires 2.2)
9. **2.3.D** — iterate-pass.sh (requires 2.3.C)
10. **2.3.G (remainder)** — Tick interruption cleanup

Steps 1-7 leave the orchestrator in a "new architecture, same
single-task-per-tick behavior" state. Steps 8-10 add the review loop.

`ORCH_MAX_PARALLEL` stays at 1 throughout Phase 2. Phase 4 of the
broader SDLC plan is where `find-ready-tasks.sh` gains collision
detection and the default can safely raise to 2.

## Risk register

| Risk | Mitigation |
|---|---|
| Tick run-time inflates with multiple parallel workers + slow ones dominate | Worker timeout (G); operator can set MAX_PARALLEL=1 to revert behavior |
| State.json writes race within a phase (multiple workers calling launch-worker.sh) | All state.json writes happen in main tick process; launch-worker.sh writes its update under a brief flock |
| Reviewer cap hit silently | safety-block label + notify; iteration count visible in PR body |
| Worktree leak when tick killed | EXIT trap cleanup (G); fallback weekly worktree prune cron (already documented in kit README) |
| review-pr.sh modifies state it shouldn't | Hardcoded `--disallowed-tools` from Phase 2 Task 2.2 spec |
| iterate-pr.sh worker addresses non-review-comment changes ("drive-by" edits) | Worker prompt instructs scope discipline (already in worker-superpower.md); reviewer catches scope creep on next pass |

## Non-goals

- **Cross-plan parallelism.** Multiple plans active at once → tick still picks the oldest in_progress one and ignores others. Multi-plan scheduling is future work.
- **Dynamic MAX_PARALLEL adjustment based on quota.** Static env var only.
- **Worker retry with different prompts.** Retries use the same prompt; if the worker can't complete it 3 times, escalate to human.
- **Reviewer disagreement resolution.** If reviewer and worker loop produces no convergence, iteration cap kicks in. No "third party" arbitration.

## Open questions

- **What's the right default for `ORCH_WORKER_TIMEOUT`?** 10 min covers typical implementation tasks; complex ones may need 20+. Likely make it configurable per-plan via plan-level frontmatter (Phase 3-style addition).
- **Should review pass spawn reviewers in parallel or serial?** Reviewers are cheap (sonnet) and independent. Parallel is fine. But: cumulative API spend per tick can spike. Worth a separate `MAX_PARALLEL_REVIEWS` env var that defaults to MAX_PARALLEL.
- **How does the tick handle a plan that's been deleted mid-flight?** If the plan file is removed while tasks are in-flight, the state.json becomes orphaned. Likely should mark all tasks blocked, archive the state, notify. Edge case; not blocking.
- **Should `iterate-pass.sh` use a different model than the original worker?** Iteration is often smaller-scope than initial work. Could default to sonnet for iteration even when the original worker used opus. Cost win, but inconsistency might confuse the worker. Defer.

## File-by-file summary

| File | Change | Sub-task |
|---|---|---|
| `orchestrator-kit/orchestrator.sh` | Rewrite into 5-phase dispatcher | 2.3.F |
| `orchestrator-kit/.claude/scripts/launch-worker.sh` | New (extracted from orchestrator.sh) | 2.3.A |
| `orchestrator-kit/.claude/scripts/sweep-merges.sh` | New | 2.3.B |
| `orchestrator-kit/.claude/scripts/review-pass.sh` | New | 2.3.C |
| `orchestrator-kit/.claude/scripts/iterate-pass.sh` | New | 2.3.D |
| `orchestrator-kit/.claude/scripts/find-ready-tasks.sh` | New (interim — Phase 4 replaces) | 2.3.E |
| `orchestrator-kit/.claude/scripts/_dispatcher_lib.sh` | New (lock + state I/O helpers) | 2.3.G |
| `orchestrator-kit/.claude/scripts/review-pr.sh` | Extended with orch:review-sha marker | 2.3.C (requires Task 2.2) |
| `orchestrator-kit/.claude/scripts/iterate-pr.sh` | New | 2.3.D |
