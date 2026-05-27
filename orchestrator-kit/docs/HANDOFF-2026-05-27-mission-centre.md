# Handoff — PLAN-06 Mission Centre implementation

**Date:** 2026-05-27
**Status:** 7 of 8 tasks merged. T8 next (docs-only).
**Spec:** `orchestrator-kit/docs/SPEC-mission-centre.md`
**Plan:** `.claude/plans/PLAN-06-mission-centre.md`
**Mockup:** `orchestrator-kit/docs/mockups/mission-centre-unified.html`
**Prior handoff (still useful):** `orchestrator-kit/docs/HANDOFF-2026-05-26-mission-centre.md`

## Plan state

```
T1 (agents.json + jokes)      ✅ MERGED  PR #45  (b7b6296)
T2 (api_costs.py)             ✅ MERGED  PR #46  (ddeef18)
T3 (api_workers last_log)     ✅ MERGED  PR #48  (ee5af75)
T4 (api_board composer)       ✅ MERGED  PR #49  (3c65f91)
T5 (frontend)                 ✅ MERGED  PR #51  (e1795fe)
T6 (route swap in app.py)     ✅ MERGED  PR #52  (2a83801)
T7 (column-builder tests)     ✅ MERGED  PR #50  (78118ec)
T8 (docs DASHBOARD/README)    → NEXT
```

Mission Centre is **live** at `localhost:5174/`. Legacy 6-panel view moved to `/dashboard`. Restart the running dashboard with `bash orchestrator-kit/.claude/scripts/dashboard.sh restart` to load the new module (Flask doesn't hot-reload).

## What changed this session (delta from 2026-05-26 handoff)

### Workflow change — pr-review-toolkit loop before every merge

**The operator established a new rule this session, saved as `feedback_pr_review_before_merge` memory:**

Before merging any PR, run the `pr-review-toolkit:review-pr` skill (or dispatch the constituent reviewers in parallel via Agent calls) on the open PR. Address every finding. Loop: review → fix → push → review again, until reviewers return clean. Only then ask the operator for the merge call.

In practice this means dispatching 3–4 specialized reviewers in parallel against each PR:
- `pr-review-toolkit:code-reviewer` — always
- `pr-review-toolkit:silent-failure-hunter` — for any code with error handling
- `pr-review-toolkit:comment-analyzer` — for code with substantial documentation
- `pr-review-toolkit:pr-test-analyzer` — for PRs touching tests OR depending on testable seams
- `frontend-architect` — for frontend PRs (a11y / UX dimension)

Round 1 is heavy/exploratory. Round 2 is verification-only with tighter prompts ("verify these specific items are fixed"). Two rounds usually converges to NO_BLOCKERS. Don't run another round for cosmetic-only changes.

### Spec deviations applied since the prior handoff

| Task | Deviation | Why |
|---|---|---|
| T3 | Defensive JSON parsing handles both single-object (current `--output-format json`) AND JSONL (future stream-json) | Forward-compat for incremental progress display |
| T4 | Agent identity uses `hashlib.md5`, NOT Python's built-in `hash()` | `hash()` is `PYTHONHASHSEED`-randomized — every dashboard restart would silently reshuffle every avatar |
| T4 | `build_board` is a pure function; `errors[]` is populated by the route handler, not inside the builder | Keeps the column-builder testable from synthetic inputs without IO |
| T4 (post-review) | Merged-PR-in-in_review → Done (not Blocked) | Race window between `gh pr merge` and `sweep-merges` would briefly flash every merging PR through Blocked |
| T4 (post-review) | `_fetch_pr_labels` caches the empty dict on error | Prevents a `gh` outage from re-shelling the CLI on every 5s frontend poll |
| T4 (post-review) | `utc_date` is a required kwarg on `build_board` (no `datetime.now()` default) | Pure-function contract; otherwise joke could flip mid-poll at 00:00 UTC |
| T5 | Token-first Cost panel headline; `$` as secondary "API-equivalent" label | Operator is on a Max subscription — tokens are the real meter |
| T5 (post-review) | `hasRenderedSuccessfully` flag keeps last-known-good DOM on transient errors | Single 5xx or network blip mustn't blank operator's view; stale-dot + alerts strip indicates instead |
| T5 (post-review) | DiceBear `<img>` checks `naturalWidth === 0` in `onload` | Catches CDN serving HTML error page with HTTP 200 — `onerror` doesn't fire for that |
| T5 (post-review) | Focus preserved across 5s re-render via `data-url` lookup | Operator no longer loses keyboard place on every poll |
| T5 (post-review) | `--text-faint` bumped from `#6e7681` to `#8b949e` for WCAG AA contrast | 3.4:1 → 5.2:1. Side-effect: collapses two-tier hierarchy with `--text-dim`. Pick intermediate `~#838c96` in a follow-up if hierarchy matters. |
| T6 | Mission Centre served via `send_from_directory(TEMPLATES_DIR, ...)` not `render_template` | board.html has no Jinja substitutions — static blob delivery is correct |
| T6 (post-review) | `_discover_blueprints` catches `Exception` not just `ImportError` | Pre-existing bug — any top-level `FileNotFoundError`/`PermissionError`/`json.JSONDecodeError` in an `api_*.py` would have 500'd the whole dashboard |

All deviations are documented in the merged PR bodies (#45 → #52).

## Outstanding follow-ups (deferred from reviewer rounds)

Non-blocking items the reviewers surfaced but I didn't fix in this session. Worth a follow-up issue or bundled into a future polish PR:

1. **Spec + mockup still show `$2.18` cost headline.** Need a small update to reflect the tokens-first display T5 actually implements. One-file edit each. Suggested in the prior handoff; never landed.

2. **`--text-faint` collapses hierarchy with `--text-dim`** after the contrast bump. Both are now `#8b949e`. Pick an intermediate value (~`#838c96` ≈ 4.7:1 ratio) that passes AA but stays visually distinct from `--text-dim`.

3. **Alerts strip dual-role** (T5 a11y reviewer). `#alerts-strip` has `role="alert" aria-live="assertive"` (correct for genuine errors), but `renderTransientError` routes "fetch failed (showing stale data)" notices through the same strip. Assertive announcement on every poll-fail is over-aggressive — split into two regions or downgrade the transient row to `aria-live="polite"`.

4. **Focus snap-to-body on card removal** (T5 a11y reviewer). `restoreFocus` silently no-ops when the data-url disappears (e.g., task merged → card moves to Done column with a different URL). Worth a SR announcement of "focus moved to X" in that case.

5. **`app.py` placeholder messages lack fix path** (T6 silent-failure reviewer). "Mission Centre frontend not installed" tells operator what, not how. Add `"run bash orchestrator-kit/install.sh"` or equivalent.

6. **`send_from_directory` permission-failure unhandled** (T6 silent-failure reviewer). If `board.html` exists but isn't readable, Flask 500s with a stack trace in logs only. Edge case.

7. **Protocol-relative URLs `//evil.com` pass the click_url guard** (T5 silent-failure reviewer). `/^(https?:\/\/|\/)/` matches `//foo`. `window.open("//foo", "_blank", "noopener,noreferrer")` resolves to `https://foo`. Localhost-only threat model, `noopener,noreferrer` limits blast radius — flagged for future hardening.

## How we work — workflow patterns to keep

### The reviewer loop (NEW — established 2026-05-27)

See above. Memory at `~/.claude/projects/-Users-rb-Documents-Github-claudecode-automation/memory/feedback_pr_review_before_merge.md`. The operator wants pr-review-toolkit on every PR before merge.

### Worktree juggling for agent-completed PRs

When background agents (via Agent tool with `isolation: "worktree"`) complete and you need to apply review fixes:

1. The agent's worktree is left at `.claude/worktrees/agent-<id>/` checked out on the PR branch and **locked**.
2. You can't `git switch <branch>` in the main worktree because it's checked out elsewhere.
3. **Fix:** `git worktree unlock <agent-path>; git worktree remove <agent-path>; git worktree add /tmp/<task>-fixes <branch>`. Apply fixes in `/tmp/`, commit, push, then `git worktree remove /tmp/<task>-fixes` when done.

### Local-verification protocol (continues from prior handoff)

GHA Actions was in `major_outage` per https://www.githubstatus.com/api/v2/components.json as of 2026-05-27. **Re-check before each PR.** If recovered, revert to standard CI flow. Until then:

```bash
# shellcheck (matches .github/workflows/ci.yml exactly)
shellcheck -S warning -e SC2164 -e SC2011 \
  $(find orchestrator-kit -type f -name "*.sh" -not -path "*/archive/*")

# kit-drift (catches root/canonical divergence)
bash orchestrator-kit/.claude/scripts/kit-upgrade.sh orchestrator-kit

# full test suite — now includes _test_board_api.sh (10 tests total)
for t in orchestrator-kit/tests/*.sh; do
  bash "$t" >/dev/null && echo "PASS $(basename $t)" || echo "FAIL $(basename $t)"
done
```

Merge with `--admin --squash --delete-branch` while CI is dead (operator must authorize "admin merge" each time).

### Kit-drift discipline (unchanged)

Edit canonical under `orchestrator-kit/.claude/scripts/...` → run `kit-upgrade.sh orchestrator-kit --apply` → re-verify with `kit-upgrade.sh orchestrator-kit` (no `--apply`) → must report 0 drift → commit both copies. `tests/` and `docs/` are kit-source-only, NOT mirrored. T8 (docs) edits only the orchestrator-kit copy.

### PR conventions (unchanged)

- Branch: `claude/plan-06-task-<N>` (or `docs/handoff-...` for handoffs)
- Title: `feat(dashboard): PLAN-06 T<N> — <description>` or `test(...)` / `docs(...)` per change kind
- Body: acceptance criteria table + local CI verification block + design notes
- One task = one PR. Operator merges via `--admin` while GHA is down.

## What to do next

### Immediate: T8 — DASHBOARD.md + README.md update

```
Task 8: Update docs (DASHBOARD.md + README.md)
depends_on: [6]   — merged ✓
touches: [orchestrator-kit/docs/DASHBOARD.md, orchestrator-kit/README.md]
acceptance: [
  "DASHBOARD.md has a new Mission Centre section describing the unified
   layout, column mapping, agent identity, and how to reach the legacy
   view at /dashboard",
  "README.md Local dashboard pointer mentions Mission Centre is the
   default landing page",
  "at least one reference to the mockup file
   orchestrator-kit/docs/mockups/mission-centre-unified.html for visual
   context",
  "no broken intra-repo links in either file"
]
```

Both files are docs-only — NOT in the kit-drift manifest. Edit only the orchestrator-kit copy. No `kit-upgrade.sh --apply` needed for these files.

Suggested structure for the new DASHBOARD.md "Mission Centre" section:

1. **Overview** — what it is (unified 7-column kanban + telemetry), what it replaces (legacy 6-panel), where to find it (`/`).
2. **Column mapping** — table of the 7 columns and their FSM-status / GH-state rules. Copy the table from SPEC-mission-centre.md "Column mapping" section, condensed.
3. **Agent identity** — per-task hash assignment, Argus pinning for reviewer, DiceBear avatars + offline fallback.
4. **Cost panel** — token-first headline, `$` as API-equivalent secondary line (call out the Max-subscription rationale).
5. **`/` vs `/dashboard`** — Mission Centre is the new default; legacy view moved to `/dashboard` for operators with bookmarks or who prefer the older layout.
6. **Visual reference** — link to `orchestrator-kit/docs/mockups/mission-centre-unified.html`.

README.md change is smaller: update the "Local dashboard" pointer (one or two sentences) to mention Mission Centre is the default landing page.

After T8 merges, the orchestrator's plan-completion check will detect all 8 tasks in terminal status (`merged`) and archive PLAN-06 automatically.

## Reference: file paths

| Purpose | Path |
|---|---|
| Spec | `orchestrator-kit/docs/SPEC-mission-centre.md` |
| Mockup (approved v2) | `orchestrator-kit/docs/mockups/mission-centre-unified.html` |
| Plan | `.claude/plans/PLAN-06-mission-centre.md` |
| Plan state (gitignored) | `.claude/plans/PLAN-06-mission-centre.state.json` |
| Mission Centre route handler (T6) | `*/dashboard/app.py` |
| Unified payload composer (T4) | `*/dashboard/api_board.py` |
| Cost rollup (T2) | `*/dashboard/api_costs.py` |
| Worker enrichment (T3) | `*/dashboard/api_workers.py` |
| Frontend (T5) | `*/dashboard/templates/board.html`, `*/dashboard/static/board.{css,js}` |
| Agent pool / jokes (T1) | `*/dashboard/static/agents.json`, `blocked_jokes.json` |
| Tests (T7) | `orchestrator-kit/tests/_test_board_api.sh` |

## Prompt for the next session

> Continuing PLAN-06 Mission Centre implementation. 7 of 8 tasks merged.
> Read `orchestrator-kit/docs/HANDOFF-2026-05-27-mission-centre.md` first
> — it has plan state, all spec deviations made so far, the workflow
> patterns to keep (pr-review-toolkit loop before every merge,
> local-verification protocol while GHA is in major_outage, kit-drift
> discipline, worktree juggling for agent PRs), and the T8 brief.
>
> Start T8: update `orchestrator-kit/docs/DASHBOARD.md` with a Mission
> Centre section and update `orchestrator-kit/README.md`'s Local
> dashboard pointer. Both are docs-only and kit-source-only (no
> kit-drift mirror). Follow the same PR pattern as T1–T7: branch
> `claude/plan-06-task-8`, local CI, push, run pr-review-toolkit
> review loop, wait for my merge call.
>
> After T8 merges, PLAN-06 is complete — confirm the state file
> archives correctly.
