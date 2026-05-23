---
auto_recommended: true
---

# PLAN-02 — monitor agent MVP

Implements the `monitor` ops agent from
[issue #4](https://github.com/weclaudecode/claudecode-automation/issues/4) —
a Phase 7 heuristic sweep that detects stalls/audit signals and files
findings as GitHub issues with hash-based deduplication. v1 is
heuristic-only; v2 (LLM-assisted investigation) is out of scope.

Plan uses the kit's `PLAN-NN-<slug>.md` format and ingests cleanly,
but is intended for **human or subagent execution** in
`claudecode-automation` — not for orchestrator-driven runs (the kit
isn't installed into its own source repo). If you later install the
kit into a fork for orchestrator-driven dogfood, the
`auto_recommended: true` frontmatter is preserved.

## Orchestrator scenarios covered (if you do run it via the kit)

- **Parallel-safe quintuplet:** tasks 2 + 3 + 4 + 5 + 6 (each heuristic
  owns disjoint files under `_heuristics/` + per-heuristic fixtures +
  per-heuristic test).
- **Dep chain:** 1 → {2,3,4,5,6} → 7.
- **Sensitive auto-flag:** task 7 touches `.github/workflows/` (CI
  shellcheck must accept the new files) AND the root `CLAUDE.md`
  architecture diagram — flagged sensitive by ingest's pattern detector,
  explicit `auto_merge: false`.
- **Decisions to log under `auto_recommended: true`:** heuristic
  thresholds (24h for H1, 7d for H3, etc.) are reasonable defaults but
  workers may tune them — log every change in `.claude/state/decisions.md`.

## Architecture (target)

- `orchestrator-kit/.claude/scripts/monitor-sweep.sh` — entrypoint
  invoked as Phase 7. Sources `_dispatcher_lib.sh`, defines the
  `monitor_finding` callback (hash → dedup → file issue), then sources
  every `_heuristics/*.sh` in glob order.
- `orchestrator-kit/.claude/scripts/_heuristics/` — one file per
  heuristic. Each is self-contained: sets `set -uo pipefail`, reads
  `$STATE_FILE` and `$REPO` from environment, calls `monitor_finding`
  if the pattern fires.
- `orchestrator-kit/tests/fixtures/monitor/` — synthetic state.json
  files and log excerpts shaped to trigger each heuristic deterministically.
- `orchestrator-kit/tests/test_monitor_sweep.sh` — Bash test runner.
  Iterates fixture pairs (positive case: triggers; negative case:
  clean), invokes the relevant heuristic against each, asserts the
  expected number of `monitor_finding` calls. Uses a stub
  `monitor_finding` that captures calls in an array instead of hitting
  `gh`.
- `orchestrator-kit/orchestrator.sh` — Phase 7 block under
  `if [ -x .claude/scripts/monitor-sweep.sh ]` guard so the kit stays
  backward-compatible.
- README + CLAUDE.md updates.

---

## Task 1: monitor-sweep.sh framework + dedup helper + fixture harness
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/monitor-sweep.sh`, `orchestrator-kit/.claude/scripts/_heuristics/.gitkeep`, `orchestrator-kit/tests/test_monitor_sweep.sh`, `orchestrator-kit/tests/fixtures/monitor/.gitkeep`]

Lay down the framework that tasks 2-6 each plug into. No heuristics
implemented yet — task 1 only ships the scaffolding.

Steps:
1. Create `orchestrator-kit/.claude/scripts/monitor-sweep.sh`:
   - `set -uo pipefail` (not `-e` — match `sweep-merges.sh` /
     `refresh-deps.sh` patterns).
   - Source `_dispatcher_lib.sh` for `state_write` (probably
     unused but available) and `find_timeout_cmd`.
   - Define `monitor_finding <hash> <title> <body>`:
     - Skip if `${MONITOR_TEST_MODE:-0}` is `1` and instead `printf` the
       hash to stderr (test runners use this).
     - `gh issue list --repo "$REPO" --label monitor:finding --state open
       --search "$hash" --json number --jq 'length'`.
     - If ≥ 1, log `monitor: dedup hit for $hash` and skip.
     - Else `gh issue create --repo "$REPO" --label monitor:finding
       --title "$title" --body "$body"`. Echo the URL.
   - Define `setup_monitor_label` — calls `gh label create monitor:finding
     --color e4e669 --description "Auto-filed by monitor-sweep.sh"
     --force` once at startup. Best-effort; never aborts.
   - Source every `.sh` file in `.claude/scripts/_heuristics/` in glob
     order. Each heuristic reads `$STATE_FILE`/`$REPO` and may call
     `monitor_finding`.
   - Print summary: `monitor-sweep: done — findings=N, deduped=M, fired=K`.
2. Create `orchestrator-kit/.claude/scripts/_heuristics/.gitkeep` so
   the directory is tracked even before heuristics land.
3. Create `orchestrator-kit/tests/test_monitor_sweep.sh`:
   - `set -uo pipefail`.
   - `MONITOR_TEST_MODE=1` exports a stub `monitor_finding` that pushes
     `$1` (the hash) into a `MONITOR_FINDINGS_OBSERVED` array.
   - Helper `assert_finding <hash>` and `assert_no_finding <hash>`.
   - Helper `run_heuristic <heuristic_file> <fixture_state>` — sets
     `STATE_FILE=<fixture>`, sources the framework + the heuristic,
     captures fires.
   - The runner walks `tests/fixtures/monitor/*_positive.json` and
     `*_negative.json` (added by tasks 2-6).
   - For now (task 1 only) just smoke-test that the framework loads
     without errors and `monitor_finding` is callable.
4. Create `orchestrator-kit/tests/fixtures/monitor/.gitkeep`.
5. `chmod +x orchestrator-kit/.claude/scripts/monitor-sweep.sh
   orchestrator-kit/tests/test_monitor_sweep.sh`.
6. Verify:
   - `shellcheck -S warning -e SC2164 -e SC2011
     orchestrator-kit/.claude/scripts/monitor-sweep.sh
     orchestrator-kit/tests/test_monitor_sweep.sh` exits 0.
   - `bash orchestrator-kit/tests/test_monitor_sweep.sh` exits 0 with
     a "framework smoke-test ok" line (no heuristic fixtures exist yet).

Commit: `feat(monitor): scaffold monitor-sweep framework + test harness`

## Task 2: H1 — orch:needs-robbie stuck PR detector
**depends_on:** [1]
**touches:** [`orchestrator-kit/.claude/scripts/_heuristics/h1_stuck_needs_robbie.sh`, `orchestrator-kit/tests/fixtures/monitor/h1_positive.json`, `orchestrator-kit/tests/fixtures/monitor/h1_negative.json`]

Detect the exact bug that stalled propscan-au for 16 hours.

Pattern: a task whose status is `in_review` AND its PR has label
`orch:needs-robbie` for >24 hours AND the task is NOT in
`auto_merge_overrides` (which would make the label intentional).

Steps:
1. `_heuristics/h1_stuck_needs_robbie.sh`:
   - `set -uo pipefail`.
   - Iterate `.tasks[]` where `.status == "in_review"` and `.pr != null`.
   - For each: check `.auto_merge_overrides[task_num]`. If `false`, skip
     (intentional sensitive task).
   - `gh pr view "$pr" --repo "$REPO" --json labels,createdAt,updatedAt`.
   - If `orch:needs-robbie` in labels AND `updatedAt` > 24h ago, call
     `monitor_finding "H1-PR$pr" "PR #$pr stuck in orch:needs-robbie
     for >24h" "<body>"`.
   - Body should include: PR URL, task number, plan file, hours stuck,
     hint that this is the same class as
     <https://github.com/weclaudecode/claudecode-automation/issues/1>.
   - Threshold is configurable via `ORCH_MONITOR_H1_AGE_HOURS` env var
     (default 24).
2. `tests/fixtures/monitor/h1_positive.json`: synthetic state.json
   with one in_review task whose PR (PR #99) has `orch:needs-robbie` in
   a recorded `_test_pr_fixtures` field the test harness reads.
   (Tests will need to stub `gh pr view` — see task 1's framework.)
3. `tests/fixtures/monitor/h1_negative.json`: same shape but the PR
   doesn't have `orch:needs-robbie`, OR the task IS in
   `auto_merge_overrides`.
4. Extend `tests/test_monitor_sweep.sh` to test both fixtures with H1.
   Recommended stub strategy: heuristic checks for `_test_pr_fixtures`
   in state.json first; if present, uses that instead of `gh pr view`.
   Document this stub-hook pattern in the heuristic's header comment
   so future heuristics use the same approach.
5. Verify: `bash orchestrator-kit/tests/test_monitor_sweep.sh`
   asserts H1 fires once on positive fixture, zero times on negative.
   `shellcheck -S warning -e SC2164 -e SC2011 ...` exits 0.

Commit: `feat(monitor): H1 — stuck orch:needs-robbie PR detector`

## Task 3: H2 — silent worker-failed-3x detector
**depends_on:** [1]
**touches:** [`orchestrator-kit/.claude/scripts/_heuristics/h2_silent_block.sh`, `orchestrator-kit/tests/fixtures/monitor/h2_positive.json`, `orchestrator-kit/tests/fixtures/monitor/h2_negative.json`, `orchestrator-kit/tests/fixtures/monitor/h2_decisions_empty.md`, `orchestrator-kit/tests/fixtures/monitor/h2_decisions_active.md`]

Detect tasks that hit retry-3-then-blocked without any audit trail —
worker failed silently and operator has no clue why.

Pattern: task `status: blocked` with `blocked_reason: worker_failed_3x`
AND `decisions.md` has zero new entries timestamped in the 24 hours
before `.blocked_at`.

Steps:
1. `_heuristics/h2_silent_block.sh`:
   - Iterate `.tasks[]` where `.status == "blocked"` and
     `.blocked_reason == "worker_failed_3x"`.
   - Parse `.blocked_at` (ISO 8601). Read
     `.claude/state/decisions.md` (path via `$DECISIONS_FILE` env
     var, default `.claude/state/decisions.md`).
   - Count `## YYYY-MM-DD HH:MM` headers with timestamps in
     [`.blocked_at - 24h`, `.blocked_at`].
   - If zero, call `monitor_finding "H2-PLAN${PLAN_NUM}-T${TASK_NUM}"
     "..." "<body>"`.
   - Body should include the task number, the run-*.json paths in
     `.claude/state/` to inspect, and a pointer that the worker may
     have failed at `claude -p` startup (before any decision-making).
2. Fixtures `h2_positive.json` + `h2_decisions_empty.md`: blocked task,
   no decisions in the relevant window.
3. Fixtures `h2_negative.json` + `h2_decisions_active.md`: blocked task,
   decisions present.
4. Test runner walks the fixture pair. The heuristic reads
   `$DECISIONS_FILE` env, so tests just point it at the fixture.
5. Verify shellcheck + `bash test_monitor_sweep.sh` H2 cases.

Commit: `feat(monitor): H2 — silent worker-failed-3x detector`

## Task 4: H3 + H5 — pipeline health detectors
**depends_on:** [1]
**touches:** [`orchestrator-kit/.claude/scripts/_heuristics/h3_slow_plan.sh`, `orchestrator-kit/.claude/scripts/_heuristics/h5_deadlock.sh`, `orchestrator-kit/tests/fixtures/monitor/h3_positive.json`, `orchestrator-kit/tests/fixtures/monitor/h3_negative.json`, `orchestrator-kit/tests/fixtures/monitor/h5_log_positive.txt`, `orchestrator-kit/tests/fixtures/monitor/h5_log_negative.txt`]

Two related heuristics (both about pipeline-not-advancing) bundled
because they share fixture style and exercise similar code paths.

### H3 — slow-plan detector

Pattern: `.status == "in_progress"`, plan ingested >7 days ago, and
`<30%` of tasks have `.status == "merged"`.

`_heuristics/h3_slow_plan.sh`:
- `.ingested_at` parse → elapsed days.
- If `>7` AND `(merged_count / total_tasks) < 0.30`, fire.
- Hash: `H3-PLAN${PLAN_NUM}`.
- Body: elapsed days, merged/total, suggestion to investigate
  individual blocked tasks via the dashboard issue.
- Threshold configurable via `ORCH_MONITOR_H3_AGE_DAYS` (default 7) and
  `ORCH_MONITOR_H3_MIN_MERGED_PCT` (default 30).

### H5 — deadlock detector

Pattern: orchestrator.log shows ≥5 consecutive ticks with
`launch-pass: no slots` AND no tasks merged between those ticks.

`_heuristics/h5_deadlock.sh`:
- Tail recent `orchestrator.log` (path via `$LOG_FILE` env var, default
  `.claude/state/orchestrator.log`).
- Parse the last 20 tick blocks (`=== tick ... ===` markers).
- Count consecutive trailing ticks ending in `launch-pass: no slots`
  with no `MERGED` lines.
- If ≥ 5, fire.
- Hash: `H5-PLAN${PLAN_NUM}-RECENT`.
- Body: count of consecutive blocked ticks, list of in_review tasks
  holding the slots.
- Threshold: `ORCH_MONITOR_H5_CONSECUTIVE_TICKS` (default 5).

Steps:
1. Implement both heuristic files per the above.
2. Fixtures for H3: state.json with `ingested_at` shifted 8 days ago,
   1/10 merged (positive) vs 5/10 merged (negative).
3. Fixtures for H5: log-tail samples with the deadlock pattern
   (positive) and a healthy log with regular merges (negative).
4. Tests: assert H3 + H5 fire correctly on positive fixtures, not on
   negative.
5. Verify shellcheck + `bash test_monitor_sweep.sh`.

Commit: `feat(monitor): H3 + H5 — slow-plan + deadlock detectors`

## Task 5: H4 + H6 — review quality detectors
**depends_on:** [1]
**touches:** [`orchestrator-kit/.claude/scripts/_heuristics/h4_reviewer_flake.sh`, `orchestrator-kit/.claude/scripts/_heuristics/h6_test_fail_pr.sh`, `orchestrator-kit/tests/fixtures/monitor/h4_reviews_positive.json`, `orchestrator-kit/tests/fixtures/monitor/h4_reviews_negative.json`, `orchestrator-kit/tests/fixtures/monitor/h6_run_positive.json`, `orchestrator-kit/tests/fixtures/monitor/h6_run_negative.json`]

### H4 — reviewer flake

Pattern: same PR HEAD SHA has been reviewed ≥3 times with alternating
verdicts (CHANGES_REQUESTED → APPROVE → CHANGES_REQUESTED, etc.).

`_heuristics/h4_reviewer_flake.sh`:
- For each `in_review` task with `.pr`, query
  `gh api repos/$REPO/pulls/$pr/reviews` (paginated).
- Group reviews by `commit_id` (head SHA at time of review).
- If any SHA has ≥3 reviews with ≥2 distinct verdicts among them, fire.
- Hash: `H4-PR${pr}-SHA${short_sha}`.
- Body: the reviews, the verdicts, suggestion that the reviewer prompt
  may need disambiguation.

Stub hook: heuristic checks for `_test_reviews_fixture` in state.json
first; if present (test mode), reads from it instead of calling gh.

### H6 — test-fail PR

Pattern: a worker's `run-plan-NN-tM-rR.json` has
`.[]|.result|fromjson|.tests_result == "fail"` but the worker still
opened a PR.

`_heuristics/h6_test_fail_pr.sh`:
- Walk `.claude/state/run-plan*.json`.
- For each, extract `.result | fromjson | .tests_result` and
  `.status`.
- If a worker reported `tests_result: "fail"` but `.status: "complete"`
  and the corresponding task in state.json has a PR — fire.
- Hash: `H6-T${task_num}-R${retry}`.

Steps:
1. Implement both heuristic files.
2. Fixtures: H4 reviews JSON with the alternating-verdict pattern; H6
   run JSON with fail-but-complete.
3. Tests assert positive/negative behavior.
4. Verify shellcheck + tests.

Commit: `feat(monitor): H4 + H6 — reviewer-flake + test-fail-PR detectors`

## Task 6: H7 — sensitive-decisions audit
**depends_on:** [1]
**touches:** [`orchestrator-kit/.claude/scripts/_heuristics/h7_sensitive_decisions.sh`, `orchestrator-kit/tests/fixtures/monitor/h7_decisions_positive.md`, `orchestrator-kit/tests/fixtures/monitor/h7_decisions_negative.md`]

Audit signal: workers are making too many sensitive-severity
decisions under `auto_recommended: true`. Worth a human read before
the plan ships.

Pattern: `.claude/state/decisions.md` has ≥3 entries with
`**Severity:** sensitive` in the current active plan's section.

Steps:
1. `_heuristics/h7_sensitive_decisions.sh`:
   - Read `$DECISIONS_FILE` (default `.claude/state/decisions.md`).
   - Extract entries scoped to the current plan via the `## YYYY-MM-DD
     HH:MM — Plan NN Task M` header (PLAN_NUM is known from
     `$STATE_FILE`).
   - Count entries with `**Severity:** sensitive`.
   - If ≥ 3 (threshold via `ORCH_MONITOR_H7_THRESHOLD`, default 3), fire.
   - Hash: `H7-PLAN${PLAN_NUM}` (single finding per plan, updates
     don't dedup-flood).
   - Body: the count, the offending decisions excerpted (first ~80
     chars of each `**Decision:**` line), suggestion to audit before
     merge.
2. Fixtures: `h7_decisions_positive.md` with 4 sensitive entries on
   Plan 01; `h7_decisions_negative.md` with 0-2.
3. Tests assert.
4. Verify shellcheck + tests.

Commit: `feat(monitor): H7 — sensitive-decisions audit detector`

## Task 7: Phase 7 wiring + ORCH_MONITOR_ENABLED + docs (sensitive)
**depends_on:** [2, 3, 4, 5, 6]
**touches:** [`orchestrator-kit/orchestrator.sh`, `orchestrator-kit/.claude/scripts/monitor-sweep.sh`, `orchestrator-kit/README.md`, `CLAUDE.md`, `.github/workflows/ci.yml`]
**auto_merge:** false

Integration task. Touches `.github/workflows/` (auto-flagged sensitive)
and the kit's root `CLAUDE.md` architecture diagram — explicit
`auto_merge: false` because of the sensitive-pattern detector AND
because the integration combines five tasks' work and benefits from
human review.

Steps:
1. `orchestrator-kit/orchestrator.sh`: insert Phase 7 between the
   existing dashboard refresh (currently Phase 6) and the final
   `echo "tick done"`. Pattern:

   ```bash
   # ---- Phase 7: monitor sweep ----
   if [ "${ORCH_MONITOR_ENABLED:-1}" = "1" ] && \
      [ -x .claude/scripts/monitor-sweep.sh ]; then
     echo "--- phase 7: monitor sweep ---"
     STATE_FILE="$STATE_FILE" REPO="$REPO_OWNER_REPO" \
       bash .claude/scripts/monitor-sweep.sh || \
       echo "warning: monitor-sweep exited non-zero (continuing)" >&2
   fi
   ```

2. `orchestrator-kit/.claude/scripts/monitor-sweep.sh`: add early
   exit if `${ORCH_MONITOR_ENABLED:-1}` != `1` (belt-and-braces with
   the orchestrator-level guard).

3. `orchestrator-kit/README.md`: add a "Monitor agent" subsection
   under the architecture description. Cover:
   - What it does (heuristics list with one-liners)
   - How to disable (`ORCH_MONITOR_ENABLED=0` in the cron line)
   - How to tune thresholds (env var list per heuristic)
   - Where findings are filed (GH Issues labelled `monitor:finding`)

4. `CLAUDE.md` (root, the kit's architecture doc): update the
   architecture diagram to include Phase 7 monitor-sweep between
   Phase 6 dashboard refresh and lock release. Add a "Key invariants"
   bullet: "Monitor findings are append-only; they never modify plan
   state, only file issues for operator attention. Dedup is hash-
   based and re-fires after 7 days if the issue is closed without
   the underlying pattern clearing."

5. `.github/workflows/ci.yml`: extend the shellcheck step (or add a
   new step) to also lint `_heuristics/*.sh` and the test runner.
   Confirm CI is still green on the integrated tree.

6. Verify:
   - Run `bash orchestrator-kit/tests/test_monitor_sweep.sh` end-to-end
     — all H1-H7 positive fixtures fire exactly once, all negative
     fixtures fire zero times.
   - `shellcheck -S warning -e SC2164 -e SC2011 ...` exits 0 on the
     integrated tree.
   - Manual smoke test against a state file from a real test target
     (propscan-au): exit 0, no false positives on a healthy plan.

Commit: `feat(monitor): wire Phase 7 + ORCH_MONITOR_ENABLED + docs`

---

## Out of scope for this plan

- LLM-assisted investigation (v2 — separate plan once v1 settles)
- `notify.sh` integration (heuristic findings are too noisy for desktop alerts)
- PR comments (findings live as issues, not on PRs)
- Automatic recovery actions (those belong in dedicated phase scripts;
  precedent: `retry-auto-merge.sh` from #3)
- `/investigate <plan-NN>` slash command (v2)

## Acceptance criteria

Mirrors issue #4's "Acceptance criteria for v1" exactly:

1. `monitor-sweep.sh` runs in <2s on a 10-20 task state file (no LLM
   calls).
2. Each H1-H7 has positive + negative fixtures and at least one
   assertion per case in the test runner.
3. Dedup correctly skips re-filing within 7 days (test with fixture
   issue-list response).
4. One bad heuristic doesn't silence the rest.
5. Phase 7 wired under `[ -x ... ]` guard for backward compatibility.
6. README documents `ORCH_MONITOR_ENABLED=0` opt-out.
