# Decisions log

Append-only record of decisions made during autonomous task execution.
The orchestrator's worker reads this on every invocation to stay
consistent with prior choices. You read it to spot drift.

Format:

```
## YYYY-MM-DD HH:MM — Plan NN Task M
**Decision:** <one line>
**Reason:** <one line>
**Reversible:** yes | no
```

---

## 2026-05-23 00:01 — Plan 02 Task 4
**Decision:** H3 fixtures use absolute `ingested_at: "2026-05-15T00:00:00Z"` (8 days before current date) so H3 positive always fires (elapsed days grows over time, never shrinks below threshold); negative suppression relies on merged% >= 30% not on age, so it stays suppressed regardless of future test dates
**Severity:** routine
**Recommended option:** n/a
**Reason:** Time-fixed fixtures that rely on elapsed time growing forward are more stable than fixtures with relative offsets; H3's two-condition AND means we can pin the positive case on the stable merged% axis

## 2026-05-23 00:01 — Plan 02 Task 4
**Decision:** H5 test reuses `h1_positive.json` as STATE_FILE (plan_file = PLAN-01, has in_review task) rather than creating a dedicated h5_state.json fixture
**Severity:** routine
**Recommended option:** n/a
**Reason:** H5 only reads STATE_FILE for the body (plan_file + in_review tasks); no new fixture reduces fixture sprawl; h1_positive.json already has both needed fields

## 2026-05-23 10:00 — Plan 02 Task 5
**Decision:** H4 uses `_test_reviews_fixture` keyed by PR number (same pattern as H1's `_test_pr_fixtures`); H6 uses `_test_run_fixtures` array in STATE_FILE (same in-fixture stub approach)
**Severity:** routine
**Recommended option:** n/a
**Reason:** Embedding test data in STATE_FILE avoids filesystem fixtures for API-backed heuristics; consistent with H1 pattern documented in h1's header comment
**Reversible:** yes

## 2026-05-23 10:01 — Plan 02 Task 5
**Decision:** H6 verdict-list python uses `"  " + r.get("state", "?")` string concatenation instead of f-string `f"  {r.get('state', '?')}"` to avoid shellcheck parsing ambiguity with curly braces in heredoc
**Severity:** routine
**Recommended option:** n/a
**Reason:** Shellcheck's heredoc parser can misread `{` inside `$()` heredoc bodies; concatenation is functionally identical and avoids the parse error
**Reversible:** yes

## 2026-05-23 00:00 — Plan 02 Task 3
**Decision:** Modified `test_monitor_sweep.sh` (outside task's touches list) to add explicit H2 test block
**Severity:** routine
**Recommended option:** n/a
**Reason:** H2 fixture prefix (`h2`) differs from heuristic name (`h2_silent_block`) so auto-discovery skips it; also `DECISIONS_FILE` env must be set per test run — both require explicit test code like the H1 section
**Reversible:** yes

## 2026-05-23 12:00 — Plan 02 Task 7
**Decision:** CI shellcheck step already covers `_heuristics/*.sh` and `tests/` via existing `find orchestrator-kit -type f -name "*.sh"` glob; added clarifying comment rather than a new step
**Severity:** routine
**Recommended option:** n/a
**Reason:** `find orchestrator-kit` recursively matches all subdirectories including `_heuristics/` and `tests/`; verified by listing matched files before editing
**Reversible:** yes

## 2026-05-31 12:00 — Plan 09 Task 3
**Decision:** Unrecognised-branch sentinel sits on `card["name"] = "unrecognised"` (not `card["agent"]`), and the rendered card adds a `plan: None` + `branch: <raw>` pair. The plan spec said "for example card.agent set to a sentinel" but the existing `_workers_panel` output schema has no `agent` field — it carries `name` + `avatar_seed` which the frontend uses to render the avatar/label.
**Severity:** routine
**Recommended option:** n/a
**Reason:** Keeping the sentinel on `name` slots into the existing schema with zero frontend changes — the workers panel renders `name` as the avatar label, so "unrecognised" surfaces immediately. Adding `plan: None` (instead of a fabricated "PLAN-?") signals "no plan attribution" to any future filter logic. Adding `branch: <raw>` gives the operator the offending string for debugging without re-reading the manifest.
**Reversible:** yes

## 2026-05-30 17:05 — Plan 08 Task 2
**Decision:** Placed `fallback_non_json_review` in `_dispatcher_lib.sh` (and mirrored to root) rather than inlining the ~80-line function in `review-pr.sh`. `_dispatcher_lib.sh` was not in the task's declared `touches` list — Task 1 ran in parallel but per `git log ada2294` only touched `review-pass.sh`, so there is no merge-conflict risk on this branch.
**Severity:** routine
**Recommended option:** yes
**Reason:** Plan spec says "Either factor the fallback logic into a tiny shell function called from review-pr.sh and unit-test it, OR test the script end-to-end with mocked gh — whichever is closer to the existing kit test style." Existing tests (`_test_emit_event.sh`) source `_dispatcher_lib.sh` and test functions directly; the same pattern lets `_test_review_fallback.sh` exercise the fallback in isolation with a `gh` stub on PATH, instead of end-to-end-mocking the whole review-pr.sh pipeline (claude -p, jq, state.json…). Function is sourced into review-pr.sh's scope via the existing `source _dispatcher_lib.sh` at line 69.
**Reversible:** yes

## 2026-05-31 16:00 — Plan 12 Task 1
**Decision:** Placed `maybe_enable_auto_merge` in `_dispatcher_lib.sh` (mirrored to root) rather than inlining in `review-pr.sh`. `_dispatcher_lib.sh` is NOT in PLAN-12 Task 1's declared `touches` list, but the helper is small (~40 lines) and benefits from isolation testing — and Task 2 (parallel) only touches plan-status.sh + orchestrator.sh, so there is no merge-conflict risk on this branch.
**Severity:** routine
**Recommended option:** n/a
**Reason:** Direct precedent from Plan 08 Task 2 (placed `fallback_non_json_review` in the lib for the same reason; logged decision 2026-05-30 17:05). Mirrors the existing test pattern — `_test_review_fallback.sh` sources `_dispatcher_lib.sh` and unit-tests its functions against a gh stub, which would be hard to replicate if the merge-gate logic were inline in review-pr.sh's main flow.
**Reversible:** yes

## 2026-05-31 16:01 — Plan 12 Task 1
**Decision:** Guarded the `maybe_enable_auto_merge` invocation in review-pr.sh by `HAS_SAFETY -eq 0 && HAS_BLOCKER -eq 0`, not by `EVENT == APPROVE`. The self-review COMMENT downgrade (PR author == gh user) flips APPROVE → COMMENT but leaves the underlying verdict clean — the merge should still fire.
**Severity:** routine
**Recommended option:** n/a
**Reason:** The verdict (safety/blocker counts) is the contract, EVENT is the GitHub-API encoding. A self-reviewed clean PR is still clean and should auto-merge per PLAN-12's intent. Tested via scenario 4 of `_test_review_fallback.sh` which exercises the helper independent of EVENT, plus scenario 6 which static-asserts the guard form in review-pr.sh.
**Reversible:** yes

## 2026-05-31 16:02 — Plan 12 Task 1
**Decision:** Scenario 6 of `_test_review_fallback.sh` covers acceptance #8's "blocker verdict does NOT trigger merge" via a static `awk` grep on review-pr.sh confirming the guard form, rather than a runtime test that drives the full script with mocked claude+gh+state. Also bolts on a `grep -v 'gh pr merge --auto'` check against launch-worker.sh to fence-post acceptance #1.
**Severity:** routine
**Recommended option:** n/a
**Reason:** `maybe_enable_auto_merge` takes no verdict argument — the helper is unconditionally called from a guarded branch in review-pr.sh, so the helper itself can't refuse a blocker verdict. The contract surface to verify IS the guard. Static-grepping the script is the most direct evidence and fires before the test reaches any gh stub, catching regressions where a refactor moves the call outside the guard. Driving review-pr.sh end-to-end would need deep mocks (claude -p JSON output, state.json fixtures, full PR-metadata stub) that mostly retest unrelated paths.
**Reversible:** yes

## 2026-05-31 14:00 — Plan 11 Task 2
**Decision:** Applied the `env -i HOME="$HOME" PATH="$PATH" bash` env-scrub inside the shared `probe_aws_exports` helper so it covers BOTH Scenario 1 and Scenario 2, rather than only Scenario 2 as the acceptance text reads literally.
**Severity:** routine
**Recommended option:** n/a
**Reason:** `probe_aws_exports` is shared between scenarios; the underlying bug (operator-env leak into the bash -c subshell) is symmetric. A leaked `AWS_REGION=ap-southeast-2` (a common operator profile region) would also silently false-positive Scenario 1, because the leaked value happens to match the expected value the test asserts. Fixing the helper once seals both holes and keeps the helper as the single source of truth for "minimal-env subshell." Acceptance #1 still holds — Scenario 2's invocation IS wrapped with env -i — and #4 explicitly requires the rest of the file (including Scenario 1) to continue behaving correctly, which it does.
**Reversible:** yes
