# PLAN-09-dashboard-silent-failures — address the 7 HIGH/MEDIUM findings from the PLAN-06 review that PLAN-07 did not cover

PLAN-07 took only the 4 *critical* findings from the multi-agent review of
the Mission Centre dashboard code. Seven remaining findings (3 HIGH, 4
MEDIUM) describe silent-failure modes where the user-facing read API
swallows errors and renders misleading or empty cards instead of
surfacing what's wrong. Same anti-pattern PLAN-07 fought against — the
errors channel that api_board.py established is the right model; the
other modules don't yet use it consistently.

Grouped by file to minimise touches collisions and keep PRs reviewable.
All 4 tasks have `depends_on: []` and **no touches overlap** — the
orchestrator's collision detector should permit true parallel execution
(same shape as PLAN-08).

The kit improvements that landed via PLAN-08 are in effect now:
- Marker regex requires HTML-comment delimiters (no body-prose false-positives).
- Dispatcher-lib fallback_non_json_review prevents infinite retry loops
  when the reviewer returns prose.

So PLAN-09 should run end-to-end autonomously; no manual rescues
expected unless a worker hits max_turns=60. PLAN-09 tasks are
intentionally scoped to one file each to stay under the cap.

## Task 1: Repo-root anchoring + observable failures in api_workers.py
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/api_workers.py`, `.claude/scripts/dashboard/api_workers.py`, `orchestrator-kit/tests/_test_board_api.sh`]
**max_turns:** 60
**acceptance:** [`_last_log_for_task around line 206 and _list_worktrees around line 301 resolve the repo root via subprocess invocation of git rev-parse show-toplevel cached at module load, not Path.cwd which is fragile when Flask is launched from outside the repo root`, `the bare except Exception return None in _last_log_for_task is replaced with specific exception catches OSError JSONDecodeError UnicodeDecodeError and a log warning on unexpected types so corrupt run-files leave a paper trail`, `the api_workers route around line 353 folds any non-None error from _list_processes into a data.errors string list field following the convention api_board established rather than the ambiguous top-level error field that the frontend never reads when data is also present`, `the workers test in _test_board_api.sh is extended with a scenario verifying repo-root anchoring works regardless of cwd AND a scenario that a corrupt run-file in the log directory does NOT crash the panel but DOES leave a log breadcrumb`, `the existing PLAN-07 scenarios in _test_board_api.sh still pass`, `shellcheck clean on _test_board_api.sh`, `kit-drift CI passes via kit-upgrade.sh apply`]

api_workers.py carries three of the seven leftover findings — group
them because they all touch the same file and all share the
fail-loud-not-silent theme.

Implementation pattern:
1. Add a module-level _repo_root function that resolves via subprocess run of git rev-parse show-toplevel, caches the result, falls back to Path.cwd on any failure.
2. Replace Path.cwd in _last_log_for_task and _list_worktrees with calls to that function.
3. Tighten the bare except Exception in _last_log_for_task to catch only the expected failure shapes; log warning on unexpected.
4. In the api_workers route, append _list_processes error (when non-None) and any worktree-manifest read failure to data.errors (initialise to empty list), and stop passing error at the envelope level.

Frontend side note: board.js already reads errors from api_board, not directly from api_workers, so the change is contained.

Commit: `fix(dashboard): api_workers anchors to repo root, surfaces silent failures via data.errors[]`.

## Task 2: Surface unrecognised models + malformed plan filenames in api_costs.py
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/api_costs.py`, `.claude/scripts/dashboard/api_costs.py`, `orchestrator-kit/tests/_test_board_api.sh`]
**max_turns:** 60
**acceptance:** [`_compute_from_tokens at api_costs.py around line 93 logs once per unique unknown model name guarded with a module-level set instead of silently returning zero with no operator-visible signal`, `the unknown-model warning is also appended to the existing load_errors list so api_board errors channel surfaces it — the same channel PLAN-07 T3 wired up for _load_state failures`, `_plan_slug_short fallback in api_costs.py around line 383 no longer skips on IndexError — instead falls back to the basename pattern api_board uses around line 183, logging the malformed name once and appending to load_errors`, `the module docstring is updated to clarify the new contract — partial reporting plus load_errors channel for any silent fallback`, `new test scenario in _test_board_api.sh writes a state file referencing a model NOT in the pricing table and asserts cost_today returns a partial total AND load_errors contains a message naming the model`, `new test scenario writes a state file with malformed plan slug no hyphens and asserts the plan still appears in per_task with basename fallback AND load_errors warns about the parse`, `existing PLAN-07 T3 and T4 tests in _test_board_api.sh still pass`, `shellcheck clean`, `kit-drift CI passes`]

Two related issues, both in api_costs.py, both about silently degrading
cost rollups instead of telling the operator something needs attention.
Reuse the recent_load_errors infrastructure PLAN-07 T3 added — same
channel for unknown-model warnings and malformed-slug warnings.

Commit: `fix(dashboard): api_costs surfaces unknown models + malformed slugs via load_errors channel`.

## Task 3: _workers_panel logs + tolerates unparseable branch names instead of silently dropping
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/api_board.py`, `.claude/scripts/dashboard/api_board.py`, `orchestrator-kit/tests/_test_board_api.sh`]
**max_turns:** 60
**acceptance:** [`_workers_panel at api_board.py around line 494 logs at warning level on the first unparseable branch occurrence per process guarded with a module-level set keyed on the branch string rather than continuing silently`, `the worktree is still rendered in the panel but with a badge or marker indicating unrecognised-branch — for example card.agent set to a sentinel like the literal string unrecognised rather than being dropped`, `new test scenario in _test_board_api.sh constructs a worktree manifest entry with a branch like wt-experimental-2 with no plan-NN-task-M form and asserts the card appears in the workers panel with the unrecognised marker AND a log breadcrumb is emitted`, `existing PLAN-07 scenarios in _test_board_api.sh still pass`, `shellcheck clean`, `kit-drift CI passes`]

The current silent-drop means an operator sees no active workers when a
live claude -p is in fact running but on a branch that doesn't match
the kit's regex. Worse failure mode than stale-rendering because it
encourages the operator to launch MORE parallel work thinking capacity
is free.

Commit: `fix(dashboard): api_board renders worktrees with unrecognised branch names instead of dropping silently`.

## Task 4: Progressive stale-data degradation in board.js
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/static/board.js`, `.claude/scripts/dashboard/static/board.js`, `orchestrator-kit/.claude/scripts/dashboard/static/board.css`, `.claude/scripts/dashboard/static/board.css`]
**max_turns:** 60
**acceptance:** [`board.js adds a separate 1-second interval that updates the nav-as-of timestamp display with seconds-since-last-success showing parenthetical age like Nm ago or Ns ago so operators glancing at the timestamp can see at-a-glance how old the visible data is — currently the timestamp does not visibly age when fetches start failing`, `after a configurable threshold of staleness defaulting to 30 seconds the board panels gain a CSS class like panel-stale that visually desaturates or dims them so the operator cannot mistake stale data for live data`, `after a second threshold defaulting to 120 seconds the cost headline switches from showing the last-known dollar value to the literal word stale so operators do not make spend decisions on rotting numbers`, `the stale CSS class is removed on the next successful fetch — recovery path tested`, `the alerts-strip and live-dot continue to function as before — these are existing PLAN-06 surfaces and must not regress`, `no test file changes required because this is a frontend behavior change — manual verification by opening the dashboard stopping the Flask backend for thirty seconds and observing the visual degradation`, `kit-drift CI passes`]

This is the one frontend-only task in the plan. The current board.js
already has renderTransientError that sets the live-dot stale class and
prepends an alerts-strip row — but the panels themselves render the
last successful payload indefinitely, with the timestamp frozen.
Operators have demonstrably per the PLAN-06 review notes misread
minutes-old data as live.

Implementation sketch:
- New _lastSuccessAt module-level variable, set in pollOnce's success path.
- New setInterval calling an updateStaleness function every second that computes Date.now minus _lastSuccessAt, updates the nav-as-of text with the parenthetical age, at 30 seconds or more adds panel-stale to the board panels container, at 120 seconds or more replaces the cost headline content with the literal string stale.
- New CSS rule for panel-stale using filter saturate and opacity to dim, with a transition for smoothness — keep it visually obvious but not garish.
- On the next successful fetch, clear all stale state.

This is a UI behavior change — no automated test scaffold matches it.
Manual verification is acceptance criterion's intended check.

Commit: `fix(dashboard): board.js progressively degrades visual rendering of stale data`.
