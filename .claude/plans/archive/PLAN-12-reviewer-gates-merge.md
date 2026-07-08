# PLAN-12-reviewer-gates-merge — close #42 (reviewer becomes the merge gate) + #93 (plan-status auto-close on archive)

Two follow-ups from the end of the 2026-05-30/31 dogfood session, both touching orchestrator semantics.

1. **#42 — workflow inversion (happy-path only)**. `launch-worker.sh` currently enables `gh pr merge --auto` immediately at PR creation; with branch protection requiring only CI, PRs auto-merge within seconds and the multi-agent reviewer never runs against them. The fix is Option 2 from the issue body: strip `--auto` from `launch-worker.sh`, move it to `review-pr.sh` on a clean verdict (no `safety_block` and no `blocker` findings). Operator has explicitly opted out of the reviewer-crash failsafe — happy path only. If the reviewer hangs or crashes, the PR sits open and the operator intervenes manually.
2. **#93 — plan-status auto-close on archive**. The `[plan-NN] status` issue created by `plan-status.sh` lives forever in the backlog after the plan archives. Fix: persist the issue number to state.json at creation; close it (with a brief final-ledger comment) in the plan-completion branch of `orchestrator.sh`.

Both target the canonical kit and the dogfood install, with `kit-drift` CI guarding the sync. Both tasks have **no touches overlap** so they run in true parallel.

## Task 1: Workflow inversion — reviewer enables auto-merge on clean verdict (closes #42)
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/launch-worker.sh`, `.claude/scripts/launch-worker.sh`, `orchestrator-kit/.claude/scripts/review-pr.sh`, `.claude/scripts/review-pr.sh`, `orchestrator-kit/tests/_test_review_fallback.sh`]
**max_turns:** 60
**acceptance:** [`launch-worker.sh around line 334 no longer calls gh pr merge --auto on the happy path — the entire AUTO_MERGE-gated block at lines 330-340 is removed and replaced with a comment explaining the workflow inversion shipped via PLAN-12 closes #42`, `launch-worker.sh continues to apply the orch:needs-robbie label for sensitive PRs (auto_merge_overrides task N is false) — the labelling is the operator-attention gate independent of the merge mechanism`, `the AUTO_MERGE variable read from state.json at launch-worker.sh line 79 may stay since it still feeds the orch:needs-robbie labelling path — alternatively rename for clarity if it no longer gates merging`, `review-pr.sh on a clean verdict — HAS_SAFETY equals 0 AND HAS_BLOCKER equals 0 — reads the per-task auto_merge_overrides from state.json — if not false then calls gh pr merge --auto --squash --delete-branch — the reviewer thereby becomes the merge gate`, `review-pr.sh on a sensitive task auto_merge_overrides task N equals false does NOT call gh pr merge — sensitive PRs remain manual-merge per existing behavior — orch:needs-robbie label was already applied by launch-worker`, `review-pr.sh on REQUEST_CHANGES verdict (safety or blocker findings present) does NOT call gh pr merge — existing labelling for orch:review-blocked and orch:safety-block continues unchanged`, `review-pr.sh on fallback_non_json_review path (PLAN-08 graceful fallback for non-JSON output) does NOT call gh pr merge — that path applies orch:review-blocked for operator attention so the merge would be wrong`, `extending _test_review_fallback.sh — or new test file orchestrator-kit/tests/_test_reviewer_merge_gate.sh — covers three scenarios — clean verdict triggers merge — sensitive task with clean verdict does NOT trigger merge — blocker verdict does NOT trigger merge`, `existing _test_review_fallback.sh scenarios continue to pass — the gh stub mocks should accommodate the new gh pr merge call sites`, `shellcheck clean on both launch-worker.sh copies and review-pr.sh copies`, `kit-drift CI passes via kit-upgrade.sh apply`]

Workflow change diagram:

Before:
- launch-worker creates PR
- launch-worker calls `gh pr merge --auto` (if not sensitive)
- Auto-merge fires when CI passes — usually before review-pass runs
- review-pass spawns reviewer (now operates on a merged PR — no-op)

After:
- launch-worker creates PR (no auto-merge enabled)
- launch-worker applies `orch:needs-robbie` for sensitive PRs (unchanged)
- review-pass spawns reviewer
- review-pr.sh on clean verdict + not-sensitive: enables auto-merge via `gh pr merge --auto --squash --delete-branch`
- Auto-merge fires when CI passes
- Sensitive PRs: still gated by operator (manual merge after `orch:needs-robbie` review)

The reviewer becomes the real gate. The operator has explicitly opted out of a reviewer-crash failsafe — if the reviewer hangs, the PR sits open until manual intervention. Acceptable trade-off per the issue body's Option 2.

Important: do NOT remove the `orch:needs-robbie` labelling in launch-worker.sh — it remains the operator-attention signal for sensitive tasks. The change is purely about WHO calls `gh pr merge --auto`, not about the safety classification.

Commit: `feat(kit): reviewer enables auto-merge on clean verdict (closes #42)`.

## Task 2: plan-status auto-close on archive (closes #93)
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/plan-status.sh`, `.claude/scripts/plan-status.sh`, `orchestrator-kit/orchestrator.sh`, `orchestrator.sh`]
**max_turns:** 60
**acceptance:** [`plan-status.sh around line 138 after successfully creating the GitHub issue persists the issue number to state.json under the key plan_status_issue via the kit standard state_write helper from _dispatcher_lib.sh`, `plan-status.sh on subsequent ticks reads plan_status_issue from state.json — if present and the issue exists treats that as the canonical reference — falls back to the existing title-grep only if the field is absent (backward compatibility for plans ingested before this change)`, `orchestrator.sh plan-completion branch — the plan-N-terminal log-line section — after computing terminal state but BEFORE the archive mv reads plan_status_issue from state.json into a local variable`, `after the archive mv succeeds — if the local variable holds a non-empty issue number — posts a brief final-ledger comment to that issue summarizing N tasks merged comma M tasks blocked comma a bullet list of merged PRs from tasks N.pr fields — then calls gh issue close on the issue`, `on any gh failure (issue already closed, network down, issue not found) the orchestrator logs a warning but does NOT fail the tick — the archive must succeed regardless`, `the gh issue close path is skipped silently if plan_status_issue is null or absent in state.json — supports plans that opted out of dashboard tracking or were ingested before the field existed`, `existing kit tests still pass — no specific test scaffold for this path yet but a new orchestrator-kit/tests/_test_plan_status_close.sh exercising the happy path via gh stub and a fixture state.json with plan_status_issue set is the right shape`, `shellcheck clean on both plan-status.sh copies and both orchestrator.sh copies`, `kit-drift CI passes via kit-upgrade.sh apply`]

Implementation flow:

`plan-status.sh` creation path (~line 138):
```bash
# Existing:
CREATED=$(gh issue create ...)
ISSUE_NUM=$(echo "$CREATED" | grep -oE '[0-9]+$')
# NEW: persist to state via state_write
state_write "$STATE_FILE" ".plan_status_issue = $ISSUE_NUM"
```

`orchestrator.sh` plan-completion branch (around the "marking done and archiving" log):
```bash
# NEW: capture before archive
PLAN_STATUS_ISSUE=$(jq -r '.plan_status_issue // empty' "$STATE_FILE")
# Existing: mv state and plan to archive/
mv "$STATE_FILE" "$ARCHIVE_DIR/"
mv "$PLAN_FILE" "$ARCHIVE_DIR/"
# NEW: close the dashboard issue
if [ -n "$PLAN_STATUS_ISSUE" ]; then
  LEDGER=$(... summarize from archived state file ...)
  gh issue comment "$PLAN_STATUS_ISSUE" --body "$LEDGER" 2>&1 \
    || echo "warning: failed to comment on #$PLAN_STATUS_ISSUE; continuing" >&2
  gh issue close "$PLAN_STATUS_ISSUE" 2>&1 \
    || echo "warning: failed to close #$PLAN_STATUS_ISSUE; continuing" >&2
fi
```

The ledger comment can be brief — task count, PR list, link to archive path. Operators consult the archived state.json for the full picture.

Commit: `feat(kit): plan-status issue auto-closes when its plan archives (closes #93)`.
