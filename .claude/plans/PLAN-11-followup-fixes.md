# PLAN-11-followup-fixes — close two valid agent-followup issues from the 2026-05-30/31 session

Two low-risk follow-ups surfaced by the kit's auto-followup mechanism during the previous session. Both are tiny exact-shape copies of fixes that already shipped or have a clear reference implementation. Bundled together because they share no touches paths and run in true parallel.

1. **#71** — `iterate-pass.sh` has the same lenient `orch:review-sha` / `orch:ci-gate-sha` extraction that PLAN-08 T1 already tightened in `review-pass.sh`. The fix is a direct copy of the two-stage `grep` pipeline from PR #72.
2. **#70** — `_test_aws_env.sh` Scenario 2 inherits the operator's exported AWS environment vars (e.g. via direnv) and reports them as "not absent". Wrap the sub-shell with `env -i` so the test asserts against a clean baseline.

Neither requires architectural decisions. Neither changes kit semantics. Both have explicit fix sketches in the original issues. PLAN-09 T2 / PLAN-10 T2 demonstrate this size of change lands first try.

## Task 1: Tighten iterate-pass.sh marker extraction (sibling fix to PLAN-08 T1)
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/iterate-pass.sh`, `.claude/scripts/iterate-pass.sh`, `orchestrator-kit/tests/_test_review_markers.sh`]
**max_turns:** 60
**acceptance:** [`iterate-pass.sh lines around 138-139 mirror the tightened two-stage grep pipeline that PLAN-08 T1 applied in review-pass.sh — first match the HTML-comment delimited form then extract the hex`, `same tightening applied to both orch:review-sha and orch:ci-gate-sha extractions in iterate-pass.sh`, `bare orch:review-sha:HEX strings in PR body prose or fenced code blocks are no longer mistaken for real markers — same scenario the PLAN-08 T1 regression test covers`, `the existing _test_review_markers.sh from PLAN-08 T1 is extended with a scenario pointing at iterate-pass.sh — same fixture body — assert iterate-pass extracts only the comment-delimited form`, `existing PLAN-08 T1 scenarios in _test_review_markers.sh still pass unchanged`, `shellcheck clean on both iterate-pass.sh copies`, `kit-drift CI passes via kit-upgrade.sh apply`]

This is a sibling-script copy of the fix in PR #72 (PLAN-08 T1). The extraction lines at `iterate-pass.sh:138-139` are byte-identical to the pre-fix `review-pass.sh:150-151`. Apply the same pattern.

If the two readers grow further sibling cases, factor the extraction into a single helper in `_dispatcher_lib.sh` and have both scripts source it. Not required for this task — keeping the diff minimal is the safer first step.

Commit: `fix(kit): iterate-pass marker extraction requires HTML-comment delimiters (sibling of #72)`.

## Task 2: `_test_aws_env.sh` Scenario 2 uses clean env to avoid operator-shell leakage
**depends_on:** []
**touches:** [`orchestrator-kit/tests/_test_aws_env.sh`]
**max_turns:** 60
**acceptance:** [`Scenario 2 in _test_aws_env.sh now wraps the orchestrator.sh sub-invocation with env -i PATH HOME bash so AWS_PROFILE, AWS_REGION, AWS_DEFAULT_REGION, CDK_DEFAULT_ACCOUNT, CDK_DEFAULT_REGION are not inherited from the operator shell`, `the test asserts each of those five vars is empty after the wrapped invocation`, `the test passes when run with AWS_PROFILE=anything bash orchestrator-kit/tests/_test_aws_env.sh — proving the env leak is sealed`, `the rest of _test_aws_env.sh — Scenarios 1, 3, etc. if present — continue to behave correctly`, `shellcheck clean on _test_aws_env.sh`, `kit-drift CI passes — _test_aws_env.sh is canonical-only test code with no root sync expected`]

Fix per the issue body — wrap with `env -i HOME="$HOME" PATH="$PATH" bash ...` so the sub-shell starts with a deterministic, minimal environment. The five vars listed in acceptance are the ones the orchestrator's AWS-env propagation sets when an `aws:` frontmatter block is present (Scenario 2 is the absent-block path).

Repro from the issue body:
```
AWS_PROFILE=anything bash orchestrator-kit/tests/_test_aws_env.sh
# Currently fails — should pass after this fix
```

Commit: `fix(tests): _test_aws_env.sh Scenario 2 uses clean env to avoid operator-shell leak`.
