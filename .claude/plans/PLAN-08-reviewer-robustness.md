# PLAN-08-reviewer-robustness — fix kit issue #63 (reviewer JSON output + body-marker false positives)

Two compounding bugs in the orchestrator's review-pass machinery surfaced
during PLAN-07 T1 review:

1. **Body-marker regex false-positives** — `review-pass.sh:150-151` reads
   `orch:review-sha:<hex>` and `orch:ci-gate-sha:<hex>` markers via a bare
   pattern match that fires on *any* occurrence in the PR body — including
   prose, code blocks, and quoted test fixtures. The writers (`review-pr.sh:458,464`)
   already emit the HTML-comment form `<!-- orch:review-sha:<hex> -->`, so
   only the reader regex needs tightening to require the delimiters.
2. **Reviewer JSON-output bypass + infinite retry loop** — the reviewer
   (Opus 4.7 currently) sometimes returns prose verbatim (e.g. the
   `/security-review` skill output) instead of the JSON envelope the
   prompt demands. `review-pr.sh:333-337` then exits 2 with no marker
   applied; the next `review-pass.sh` tick sees `head != last_reviewed_sha`
   and re-spawns the reviewer. At ~$2.19 per failed review and the kit's
   default `*/5` cadence, this is a ~$26/hour burn rate until manual
   intervention.

Filed as issue [#63](https://github.com/weclaudecode/claudecode-automation/issues/63).

Both fixes target the canonical kit at `orchestrator-kit/` AND the
dogfood install at the repo root. The `kit-drift` CI job fails any PR
that only updates one side; workers should edit canonical, run
`bash orchestrator-kit/.claude/scripts/kit-upgrade.sh orchestrator-kit --apply`,
and verify with `git diff` before committing. The two tasks have **no
touches overlap**, so the orchestrator's collision detector allows them
to run in parallel.

## Task 1: Tighten review-sha / ci-gate-sha marker extraction to require HTML-comment delimiters
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/review-pass.sh`, `.claude/scripts/review-pass.sh`]
**max_turns:** 60
**acceptance:** [`review-pass.sh marker-read regex requires HTML-comment delimiters: <!-- orch:review-sha:HEX --> with optional whitespace inside the comment`, `same tightening applied to the orch:ci-gate-sha:HEX marker on the next line`, `bare orch:review-sha:HEX in PR body prose or code blocks is NOT matched`, `the existing writers in review-pr.sh remain unchanged (they already emit the HTML-comment form so no migration needed)`, `shellcheck clean on both review-pass.sh copies`, `kit-drift CI passes (root install in sync via kit-upgrade.sh --apply)`]

Replace the two `grep -oE 'orch:review-sha:[a-f0-9]+' | head -1 | cut -d: -f3`
extractions at `review-pass.sh:150-151` with a regex that requires the
HTML-comment delimiters: `<!--\s*orch:review-sha:[a-f0-9]+\s*-->`. After
matching, strip the delimiters to extract just the hex. A clean pattern:

```bash
LAST_SHA=$(echo "$PR_BODY" \
  | grep -oE '<!-- *orch:review-sha:[a-f0-9]+ *-->' \
  | head -1 \
  | grep -oE '[a-f0-9]{7,40}')
```

(The 7-40 hex range allows short and full SHA forms; the writer at
`review-pr.sh:464` uses `$HEAD_OID` which is a full 40-char SHA.) Apply
the same shape to the `orch:ci-gate-sha` extraction one line down.

No test scaffolding currently exists for these scripts. Add a minimal
inline test at the bottom of the new test file
`orchestrator-kit/tests/_test_review_markers.sh` (create it):

- Construct a PR body string with the bare form `orch:review-sha:cafef00d`
  inside backticks (mimicking PLAN-07 T1's case) AND a real marker
  `<!-- orch:review-sha:deadbeef1234567 -->` later in the body.
- Source the extraction logic (factored into a tiny shell function in
  `_dispatcher_lib.sh` if cleaner, or inline-test the regex itself with
  `grep -oE`).
- Assert the extracted SHA is `deadbeef1234567`, not `cafef00d`.

Document the marker convention in `orchestrator-kit/docs/PLAN-FORMAT.md`
or `orchestrator-kit/CLAUDE.md` is OPTIONAL for this task — primary
deliverable is the script fix. Skip if it would push past max_turns.

Commit: `fix(kit): review-pass marker extraction requires HTML-comment delimiters`.

## Task 2: Graceful fallback when reviewer returns non-JSON + prompt hardening
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/review-pr.sh`, `.claude/scripts/review-pr.sh`, `orchestrator-kit/.claude/prompts/reviewer-system.md`, `.claude/prompts/reviewer-system.md`]
**max_turns:** 60
**acceptance:** [`reviewer-system.md restates the JSON-only requirement at the TOP of the file (currently only at the end after a long acceptance block) — operators reading top-down see it first`, `reviewer-system.md adds a concrete final-message rule: your final assistant message must be valid JSON starting with { and ending with } — no prose, no markdown fences, no leading commentary`, `review-pr.sh fallback branch when VERDICT_JSON is empty: instead of exiting 2 with no marker applied, the script applies <!-- orch:review-sha:HEAD_OID --> to the PR body (so review-pass does not infinite-loop on the same SHA), applies the orch:review-blocked label (so iterate-pass picks up the PR for operator-facing iteration), posts an explanatory comment containing the raw reviewer output (head -40) and a synthetic blocker finding noting the JSON failure, and exits 0 with a log line acknowledging the fallback`, `the existing successful-JSON path is untouched`, `the fallback comment is idempotent on re-runs (does not duplicate if the marker is already present in the body)`, `shellcheck clean on both review-pr.sh copies`, `kit-drift CI passes (root install in sync via kit-upgrade.sh --apply)`]

The reviewer-system.md prompt currently places the JSON requirement at the
very end of the file (line ~210), after the verdict schema and acceptance
criteria block. The model has demonstrably ignored it in production
(PLAN-07 T1). Two complementary changes:

1. Add a 3-4 line preamble at the very top: bold "OUTPUT FORMAT:" header,
   the JSON requirement, the "starts with `{`" rule. The first thing the
   model sees should be the contract.
2. Strengthen the tail with the explicit "final assistant message starts
   with `{`" rule.

In `review-pr.sh`, replace the current bail-out at lines 333-337 with a
fallback that mirrors the kit's existing "blocker found" path lower in
the file but skips the inline-review machinery (which requires structured
findings). The fallback should:

- Apply `orch:review-sha:$HEAD_OID` marker by editing the PR body — copy
  the pattern from the successful path at line ~458 (strips any prior
  marker via `sed -E '/<!-- orch:review-sha:[a-f0-9]+ -->/d'` then
  appends the new HTML-comment form).
- Apply the `orch:review-blocked` label via `gh pr edit "$PR_NUM" --add-label`.
- Post a top-level PR comment via `gh pr comment` with the body:

  ```
  **Reviewer produced non-JSON output — synthetic blocker applied.**

  The orchestrator's review-pr.sh expects a JSON verdict envelope but the
  reviewer returned prose. The raw output (first 40 lines) is below.

  Operator action: read the reviewer's prose verdict, decide whether the
  PR should be approved or revised, then either (a) merge manually and
  apply the marker, or (b) remove `orch:review-blocked` and let
  iterate-pass run, then re-trigger review.

  <details><summary>Raw reviewer output</summary>

  \`\`\`
  <first 40 lines of reviewer prose>
  \`\`\`

  </details>
  ```

- Exit 0 (not 2) so the orchestrator log treats the tick as healthy.

Test scaffolding: add `orchestrator-kit/tests/_test_review_fallback.sh`
that:

- Fakes the reviewer run output by writing a fixture file containing the
  prose-output shape the kit saw on PLAN-07 T1 (`/security-review` markdown
  output — sample is in issue #63).
- Either factor the fallback logic into a tiny shell function called from
  `review-pr.sh` and unit-test it, OR test the script end-to-end with
  mocked `gh` (whichever is closer to the existing kit test style — the
  board API tests favor end-to-end with synthetic JSON fixtures, so use
  that pattern).
- Assert the resulting (mocked) PR body contains exactly one
  `<!-- orch:review-sha:HEAD --> ` marker, the `orch:review-blocked`
  label was applied, and the comment was posted.

Commit: `fix(kit): graceful fallback when reviewer returns non-JSON + prompt hardening`.
