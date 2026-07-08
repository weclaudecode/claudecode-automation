# PLAN-07-dashboard-bugfixes — fix four cross-confirmed criticals from the PLAN-06 review

Four high-impact bugs surfaced by a multi-agent review of the Mission Centre
code that landed in PLAN-06. Each fix is isolated to one production file +
the shared test harness; there are no cross-file refactors. The findings, in
priority order:

1. **`gh pr list --limit 30` truncation** misclassifies older `in_review`
   tasks as **Blocked** on the board. `prs_by_num.get(pr_num)` returns
   `None` for any PR outside the most recent 30, then both `pr_merged` and
   `pr_open` are `False`, and `_column_for_task`'s defensive branch sends
   the task to the Blocked column. Operators looking at a board with
   long-running plans see safety alarms that aren't real.
2. **`_fetch_pr_labels` caches an empty labels dict for 30 s on `gh`
   failure** — and the error string surfaces only on the *first* poll
   inside that window. Subsequent polls return `({}, None)`, so the
   sensitive-flag column-placement code (which requires the
   `orch:needs-robbie` label) silently lets sensitive in-review tasks
   migrate from **Blocked** into **Ready For Review**. This is the same
   class of failure as the PR #25 incident (`jq // operator flipping
   sensitive=false to true`) — operator may approve a sensitive PR
   without realising it should have stayed gated.
3. **`api_costs._load_state` swallows `OSError`/`ValueError` and returns
   `{}` with no logging.** A corrupted state file produces a "$0 today"
   cost headline with no operator-visible signal. The module docstring
   explicitly codifies the anti-pattern; the policy is correct for hook
   code, wrong for a user-facing read API.
4. **`/api/costs` route has a blanket `except Exception` that returns
   200 OK with `data=null, error="..."`.** Programmer errors (KeyError,
   AttributeError, schema drift) are swallowed; nothing in `board.js`
   reads `envelope.error` when `envelope.data` is present, so the string
   lands in a black hole.

All changes target the canonical kit at `orchestrator-kit/.claude/scripts/dashboard/`
AND the dogfood install at `.claude/scripts/dashboard/`. The `kit-drift` CI
job (added in PR #43) fails any PR that updates only one side. Each task's
acceptance includes the drift check explicitly. Workers should edit the
canonical copy, run `bash orchestrator-kit/.claude/scripts/kit-upgrade.sh
orchestrator-kit --apply` before committing, and verify with `git diff` that
both trees match.

## Task 1: Fix `gh pr list` truncation misclassifying in_review tasks as Blocked
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/api_github.py`, `orchestrator-kit/.claude/scripts/dashboard/api_board.py`, `.claude/scripts/dashboard/api_github.py`, `.claude/scripts/dashboard/api_board.py`, `orchestrator-kit/tests/_test_board_api.sh`]
**acceptance:** [`api_github.py raises the gh pr list --limit from 30 to 100`, `build_board in api_board.py handles pr_obj is None for a task with status in_review by routing on task.status alone (not the PR-state override) so an absent PR does not fall to the Blocked defensive branch`, `_column_for_task contract unchanged: callers still pass the actual pr_open/pr_merged values when a PR object is present`, `a unit test in _test_board_api.sh covers the in_review with pr_obj None scenario and asserts the column is in_review or ready_for_review (not blocked)`, `the existing PLAN-06 T7 tests in _test_board_api.sh still pass unchanged`, `shellcheck clean on _test_board_api.sh`, `kit-drift CI passes (root install in sync via kit-upgrade.sh --apply)`]

Edit `api_github.py` to change the `--limit` value in the `gh pr list` call.
Edit `api_board.py:build_board` so that when `pr_obj is None` for a task
whose `status == "in_review"`, the column placement falls back to
`_column_for_task` with `pr_open=False, pr_merged=False` only when the task
is actually `pending`/`in_progress`/`merged`/`blocked` — for `in_review`
specifically, return `"in_review"` (or `"ready_for_review"` if the sentinel
labels are also absent — same logic as the in_review branch at lines
296-302 but skipping the `pr_open` requirement). A clean way to express
this: introduce a small helper `_column_when_pr_missing(status)` that the
`pr_obj is None` branch calls, separate from `_column_for_task` (which can
keep its current strict semantics).

Add a test to `tests/_test_board_api.sh` that constructs a state with one
task in `in_review` whose `pr` number is not present in the `gh_prs` list
(simulating either truncation or a slow `gh` sync), runs `build_board`,
and asserts the task's card is in the `in_review` or `ready_for_review`
column — NOT `blocked`.

Commit: `fix(dashboard): pr-list truncation no longer misclassifies in_review tasks as blocked`.

## Task 2: Fix `_fetch_pr_labels` empty-cache bypassing sensitive-flag safety
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/api_board.py`, `.claude/scripts/dashboard/api_board.py`, `orchestrator-kit/tests/_test_board_api.sh`]
**acceptance:** [`_pr_meta_cache tuple shape changes from (timestamp, dict) to (timestamp, dict, err) where err is None on success and a non-empty error string on failure`, `_fetch_pr_labels returns the cached err on every cache hit until the next successful refetch (not just the first poll after failure)`, `on a successful refetch the cached err is cleared back to None`, `_reset_pr_label_cache test hook still works (sets _pr_meta_cache to None)`, `a unit test in _test_board_api.sh exercises three polls inside a single TTL window: first poll fails (gh returns nonzero), second poll within TTL returns the cached error (not None) and an empty labels dict, third poll after a forced cache reset succeeds and clears the error`, `the existing PLAN-06 T7 tests in _test_board_api.sh still pass unchanged`, `shellcheck clean on _test_board_api.sh`, `kit-drift CI passes (root install in sync via kit-upgrade.sh --apply)`]

In `api_board.py`, change `_pr_meta_cache` from a two-tuple
`(timestamp, labels_by_pr)` to a three-tuple
`(timestamp, labels_by_pr, err)`. Both the cache-hit branch and the
cache-miss-then-fetch branch must return `(labels_by_pr, cached_err)`.
On the success path, `err` is `None`; on the fetch-error path, `err` is
the populated error message and the cache stores it. The `errors[]`
channel in `/api/board` already surfaces `err` to the frontend's
`alerts-strip`, so the operator continues to see the warning banner on
every poll throughout the outage instead of just the first one.

Watch for the `_reset_pr_label_cache` test hook at the bottom of the
file — it sets `_pr_meta_cache = None`. That continues to work since
`None` is still the "no cache present" sentinel.

Add a test to `tests/_test_board_api.sh` covering the
"three polls inside a TTL window" scenario described in acceptance #5.
The test should be able to fake the `gh` failure deterministically —
use the existing test patterns in `_test_board_api.sh` for guidance
(monkey-patching subprocess calls, fixture state files, etc.).

Commit: `fix(dashboard): pr-label cache surfaces gh outage error on every poll, not just the first`.

## Task 3: Surface state-file corruption in `api_costs` instead of zero'ing the panel
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/api_costs.py`, `orchestrator-kit/.claude/scripts/dashboard/api_board.py`, `.claude/scripts/dashboard/api_costs.py`, `.claude/scripts/dashboard/api_board.py`, `orchestrator-kit/tests/_test_board_api.sh`]
**acceptance:** [`_load_state in api_costs.py emits a log.warning naming the path and exception type when OSError or ValueError occurs`, `_load_state continues to return empty dict on failure (do not raise — callers depend on this contract) but the warning is logged unconditionally on every load failure`, `api_costs.py exposes a module-level function load_errors that returns a list of strings containing the accumulated load error messages from the most recent cost_today or tokens_today or per-task aggregation call`, `the error list is reset at the start of each aggregation pass (cost_today, tokens_today, the /api/costs route) so stale errors do not leak across requests`, `api_board.py /api/board endpoint calls api_costs.load_errors after building the board and folds the messages into the existing errors payload with a source label like api_costs`, `the module docstring at the top of api_costs.py is updated to remove the claim that load failures return zero silently — the new policy is return fallback but log and surface via load_errors`, `a unit test in _test_board_api.sh writes a truncated state.json fixture, calls cost_today, asserts the result is the expected fallback AND that load_errors returns a non-empty list whose entry mentions the bad path`, `the existing PLAN-06 T7 tests still pass`, `shellcheck clean on _test_board_api.sh`, `kit-drift CI passes (root install in sync via kit-upgrade.sh --apply)`]

Pattern: keep the best-effort return-on-failure contract (callers
genuinely cannot raise here — `cost_today` runs across N state files and
must not abort on one bad file), but couple it with a thread-safe
module-level error list that the `/api/board` composer reads at the end
of each request.

A simple implementation: a module-level `_recent_load_errors: list[str]`
guarded by a `threading.Lock`. `_load_state` appends on failure; the
public entry points (`cost_today`, `tokens_today`, the `/api/costs`
route) clear the list at the start of their work. `load_errors()`
returns a copy.

In `api_board.py`, after `cost_fn(...)` calls finish (i.e. after the
column-building loop), call `api_costs.load_errors()` and append each
message to the existing `errors[]` list with a `source: "api_costs"`
label.

Update the module docstring (lines 30-50 of `api_costs.py`) to document
the new contract.

Add a test that writes a truncated state file (e.g. a JSON object with
the closing brace removed), calls `cost_today`, and asserts both the
zero-cost fallback and the populated error message.

Commit: `fix(dashboard): api_costs surfaces state-file load errors via /api/board errors channel`.

## Task 4: Replace blanket except Exception in /api/costs route with per-file scoping
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/api_costs.py`, `.claude/scripts/dashboard/api_costs.py`, `orchestrator-kit/tests/_test_board_api.sh`]
**acceptance:** [`the blanket except Exception wrapping the entire /api/costs route body (around line 403-404 in api_costs.py) is removed`, `try/except is moved to the inner per-state-file loop and catches only OSError, json.JSONDecodeError, ValueError, and KeyError (the schema-drift family) — not bare Exception`, `caught errors are appended to a payload-level errors list which is included in the response envelope`, `uncaught programmer errors (AttributeError, TypeError, RuntimeError) propagate to Flask and produce a 500 — so they show up in dashboard.log and the frontend transient-error rendering path`, `the existing happy-path /api/costs test in _test_board_api.sh still passes`, `a new test exercises the per-file catch: a state file with a malformed task dict triggers a KeyError inside the loop, the route returns 200 with errors list containing a message mentioning the bad path, and the per_task payload contains entries from the OTHER (good) state files`, `shellcheck clean on _test_board_api.sh`, `kit-drift CI passes (root install in sync via kit-upgrade.sh --apply)`]

Concretely: the `try` at the top of the route handler currently wraps
the entire per-state-file loop. Move the `try/except` to wrap a single
loop iteration only, so one bad state file does not nuke the whole
payload. Catch the specific exception types that genuinely come from
file-shape problems; let everything else raise.

The payload envelope should grow an `errors` field (an array of strings)
alongside the existing `per_task` and totals. Frontend already knows
how to render `errors[]` from `/api/board`; the same shape is appropriate
here even if no current frontend reads `/api/costs` directly. Future
operators or curl-debuggers will see the messages.

Add a test that constructs two state files — one well-formed, one with a
malformed task dict (e.g. a task value that isn't a dict, triggering an
`AttributeError` on `t.get(...)`) — and asserts that the route returns
200 with `errors[]` populated AND that the good state file's per-task
entries are present in the payload.

Commit: `fix(dashboard): /api/costs scopes try/except per-file, surfaces errors instead of swallowing the entire payload`.
