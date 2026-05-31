# PLAN-10-orchestrator-speedups — three orchestrator speed-ups surfaced during the 2026-05-30/31 PLAN-07/08/09 session

Three independent improvements to the orchestrator's wall-clock throughput, scoped from observations in the 2026-05-30/31 dogfood session that ran PLAN-07, PLAN-08, and PLAN-09 end-to-end. All three reduce the cost of running a plan; none change the FSM, the safety gates, or the auto-merge sensitive-flag path.

1. **`ORCH_MAX_TURNS` default of 30 is too tight.** During the dogfood session, three workers across PLAN-07/08/09 hit the default cap (`max_turns=30`) on bigger-scope tasks before reaching `commit + push`. Each rescue cost ~$3-6 of wasted worker tokens plus ~3-4 minutes of operator time to verify-and-rescue the worktree manually. The empirical landing zone for the rescued tasks was 50-65 turns — moving the default to 60 makes the common case land first try.
2. **`ingest-plan.sh` does not warn about touches-collisions across tasks.** PLAN-09 was authored expecting four true-parallel workers but actually serialized three of them because tasks 1/2/3 all listed `tests/_test_board_api.sh` in their `touches` (the orchestrator's `find-ready-tasks.sh` correctly held them back to prevent concurrent worker stomps on the test file). The collision was only discovered at runtime when launch-pass reported `launching 2 task(s) … 1 4` instead of `1 2 3 4`. A pre-ingest warning would have prompted the author to split the test file, save ~15 minutes per plan of similar shape.
3. **README's cron cadence guidance is `*/5` (every 5 minutes).** That choice was conservative when the kit was first published; in the current session the realistic ceiling was clearly higher (worker runtimes are 3-10 min; CI is 30-60 s; auto-merge fires immediately on CI green). At `*/5`, two consecutive ticks both fall in the same worker cycle, so half the ticks just confirm "nothing's ready yet." `*/2` gives a tighter feedback loop without measurably increasing token cost (each tick is mostly no-op when there's no transition; sweep-merges + review-pass have early-return paths).

All three changes target the canonical kit at `orchestrator-kit/` and the dogfood install at the repo root, with `kit-drift` CI guarding the sync. None of the three tasks share `touches` paths — true-parallel candidate.

## Task 1: Bump default `ORCH_MAX_TURNS` from 30 to 60
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/launch-worker.sh`, `.claude/scripts/launch-worker.sh`, `orchestrator-kit/.claude/scripts/iterate-pr.sh`, `.claude/scripts/iterate-pr.sh`, `orchestrator-kit/docs/PLAN-FORMAT.md`]
**max_turns:** 60
**acceptance:** [`launch-worker.sh around line 178 changes the default from 30 to 60 in MAX_TURNS PER_TASK_MAX_TURNS ORCH_MAX_TURNS resolution chain`, `iterate-pr.sh around line 284 changes the default from 30 to 60 in MAX_TURNS ORCH_MAX_TURNS resolution chain`, `the comment on launch-worker.sh line 171 about precedence updates the literal 30 to 60`, `PLAN-FORMAT.md section on max_turns updates the literal default from 30 to 60 with a note that the bump was made after empirical evidence from the 2026-05-30/31 dogfood session`, `existing per-task max_turns overrides continue to work — precedence is plan-value beats env beats default`, `shellcheck clean on both copies of launch-worker.sh and iterate-pr.sh`, `kit-drift CI passes via kit-upgrade.sh apply`]

Three tiny replacements:
- `launch-worker.sh:178` — `${PER_TASK_MAX_TURNS:-${ORCH_MAX_TURNS:-30}}` becomes `${PER_TASK_MAX_TURNS:-${ORCH_MAX_TURNS:-60}}`.
- `iterate-pr.sh:284` — `${ORCH_MAX_TURNS:-30}` becomes `${ORCH_MAX_TURNS:-60}`.
- `launch-worker.sh:171` — update the comment that says "default 30" to "default 60".
- `PLAN-FORMAT.md` — section on `max_turns:` task field — update the prose mentioning the default value.

Worker prompt and the precedence chain are unchanged.

Commit: `fix(kit): bump default ORCH_MAX_TURNS from 30 to 60 (empirical rescue evidence)`.

## Task 2: `ingest-plan.sh` warns when multiple tasks share a touches path
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/ingest-plan.sh`, `.claude/scripts/ingest-plan.sh`]
**max_turns:** 60
**acceptance:** [`ingest-plan.sh after the per-task parsing block computes for each touches path the set of task numbers listing it`, `for every path that appears in 2 or more tasks the script emits a warning to stderr — recommended phrasing is — warning colon N tasks share touches path PATH — they will serialize at runtime via the collision detector — consider splitting if true-parallel execution is desired with the colliding task numbers listed`, `the warning does NOT block ingest — exit code stays 0 — because some authors deliberately serialize tasks via shared touches and the warning is advisory`, `the warning is omitted when no collisions exist`, `the warning is printed once per colliding path even if a path appears in 4 tasks — single message listing all task numbers`, `existing ingest-plan.sh tests continue to pass`, `shellcheck clean on both copies of ingest-plan.sh`, `kit-drift CI passes`]

Implementation hint (the script is shell + gawk + python3 for yaml; pick whichever is idiomatic for the existing parsing path):

```bash
# After all tasks parsed into a temporary structure that holds touches per task:
python3 -c "
import json, sys
tasks = json.loads(sys.stdin.read())
path_to_tasks = {}
for t in tasks:
    for p in t['touches']:
        path_to_tasks.setdefault(p, []).append(t['task'])
for p, ns in sorted(path_to_tasks.items()):
    if len(ns) >= 2:
        print(f'warning: {len(ns)} tasks share touches path {p} — they will serialize at runtime via the collision detector — consider splitting if true-parallel execution is desired (tasks: {\", \".join(str(n) for n in ns)})', file=sys.stderr)
"
```

(The exact integration depends on where the existing python invocation happens in `ingest-plan.sh` — fold this into the same python block to avoid spawning a second interpreter.)

Commit: `feat(kit): ingest-plan warns about touches-collision serialization`.

## Task 3: README cron cadence guidance — `*/5` to `*/2`
**depends_on:** []
**touches:** [`orchestrator-kit/README.md`]
**max_turns:** 60
**acceptance:** [`all four mentions of every-5-minutes cron (*slash*5) in README.md around lines 187 203 387 521 update to every-2-minutes (*slash*2)`, `the prose paragraph at line 187 updates from Schedule trigger e.g. every 5 minutes to Schedule trigger e.g. every 2 minutes with a brief rationale citing the 2026-05-30 and 2026-05-31 dogfood session findings — worker runtime 3 to 10 minutes — CI 30 to 60 seconds — auto-merge fires on green — so 2-minute cadence keeps the feedback loop tight without measurably raising token cost since most ticks are early-return no-ops`, `the slash-loop example at line 208 updates from /loop 5m to /loop 2m`, `no changes to any script — this is a docs-only update`, `kit-drift CI passes — README is canonical-only no root copy expected`]

Pure docs update. Four cron-cadence references + one `/loop` example + a one-paragraph rationale.

Commit: `docs(kit): recommend */2 cron cadence (was */5) — empirical evidence`.
