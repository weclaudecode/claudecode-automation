# Handoff — PLAN-06 Mission Centre implementation

**Date:** 2026-05-26
**Status:** 2 of 8 tasks merged. T3 next. GitHub Actions degraded → local-verification protocol in effect.
**Spec:** `orchestrator-kit/docs/SPEC-mission-centre.md`
**Plan:** `.claude/plans/PLAN-06-mission-centre.md`
**Mockup:** `orchestrator-kit/docs/mockups/mission-centre-unified.html` (the approved visual reference)

## Where we are in the 8-task graph

```
T1 (agents.json + jokes)      ✅ MERGED  (commit b7b6296, PR #45)
T2 (api_costs.py)             ✅ MERGED  (commit ddeef18, PR #46)
T3 (api_workers.py extension) → NEXT
T4 (api_board.py)             depends on T1, T2, T3
T5 (frontend)                 depends on T4
T6 (app.py route swap)        depends on T4, T5
T7 (_test_board_api.sh)       depends on T2, T4
T8 (docs DASHBOARD/README)    depends on T6
```

## What's merged so far

### T1 — `static/agents.json` + `static/blocked_jokes.json`
21-entry agent pool (20 workers: Pip, Bento, Nova, Echo, Glitch, Bug, Mochi, Cosmo, Pixel, Spark, Tofu, Otter, Pepper, Patch, Loop, Snap, Tweak, Zog, Boop, Comet + reviewer Argus). 20 distinct blocked-card jokes. Both copies (canonical + root install) in sync.

### T2 — `api_costs.py` (Max-subscription-aware)
**Important deviation from spec:** Reads from `state.tasks[N].usage.runs[]` (already populated by `_dispatcher_lib.sh:update_task_usage`), NOT from `run-*.json` files. This catches reviewer cost (which `review-pr.sh` writes to a tmpfile + trap-deletes) and trusts `claude -p`'s canonical `total_cost_usd`. Pricing table remains as documented fallback.

**Max-awareness:** On a Max subscription the `$` number is *notional* (API-equivalent). Module exposes both:
- `cost_for_task(plan, task)` → float USD (notional)
- `cost_today()` → `{today_usd, by_role, yesterday_usd, this_week_usd}`
- **`tokens_for_task(plan, task)`** → `{input, output, cache_read, cache_write, total}`
- **`tokens_today()`** → full breakdown + `by_role` + yesterday/week
- `/api/costs` returns both `today_tokens` and `today_cost` plus per-task `{tokens, cost_usd}`.

T5 (frontend) will render **tokens as headline, $ as secondary "API-equivalent" label**.

## Pending follow-up: spec + mockup update

The SPEC and mockup still describe a `$2.18` cost headline. Before or alongside T5, update both to show tokens as headline. Scope is small — one file edit each. Can be a tiny PR after T3-T4 land, or bundled with T5.

## What to do next

### Immediate: T3 — `api_workers.py` extension

Add a `last_log` field to each entry in the `/api/workers` response.

- Source: tail of the worker's `run-plan<NN>-t<task>-r<retry>.json` (newest matching, by mtime). Same file layout as T2.
- Pluck the most recent meaningful line: assistant text, tool-use summary, or final result. Use the existing `extract_usage_summary` / `update_task_usage` pattern in `_dispatcher_lib.sh` as a guide for how the JSON is shaped.
- Best-effort: `null` or omit field if the file is missing/unparseable. Never raise.
- Touches both `orchestrator-kit/.claude/scripts/dashboard/api_workers.py` AND `.claude/scripts/dashboard/api_workers.py` (kit-drift discipline).
- Acceptance criteria are in PLAN-06 T3.

### After T3: T4 — `api_board.py` composer
Reads T1 (agents.json) + T2 (api_costs / tokens) + T3 (api_workers with last_log) and composes `/api/board`. Spec API surface section has the exact JSON shape.

## How we work — patterns to keep

### Protocol: local-verification (because GitHub Actions is degraded)

GHA was reporting "degraded performance" on 2026-05-26 and silently failed to run CI on PRs #45 and #46. Until it recovers:

1. Implement on `claude/plan-06-task-N` branch.
2. Run **locally** the exact CI commands and capture output:
   ```bash
   # shellcheck (matches .github/workflows/ci.yml exactly)
   shellcheck -S warning -e SC2164 -e SC2011 \
     $(find orchestrator-kit -type f -name "*.sh" -not -path "*/archive/*")

   # kit-drift (catches root/canonical divergence)
   bash orchestrator-kit/.claude/scripts/kit-upgrade.sh orchestrator-kit

   # full test suite
   for t in orchestrator-kit/tests/*.sh; do bash "$t" >/dev/null && echo "PASS $(basename $t)" || echo "FAIL $(basename $t)"; done
   ```
3. Inline an acceptance-criteria proof in the PR body / comment with explicit ✓ per criterion.
4. Operator merges with `--admin` flag when local verification is clean.
5. **Re-check `https://www.githubstatus.com/api/v2/components.json` → Actions component** before each PR. If Actions has recovered (`"operational"`), revert to normal CI flow.

### Kit-drift discipline (critical)

Every kit-owned file lives in TWO locations:
- `orchestrator-kit/.claude/scripts/...` (canonical source)
- `.claude/scripts/...` (root dogfood install)

The `kit-drift` CI job (and `kit-upgrade.sh orchestrator-kit`) fails if they diverge. Workflow:
1. Edit canonical copy under `orchestrator-kit/.claude/scripts/...`.
2. Run `bash orchestrator-kit/.claude/scripts/kit-upgrade.sh orchestrator-kit --apply` to sync to root.
3. Re-verify with `bash orchestrator-kit/.claude/scripts/kit-upgrade.sh orchestrator-kit` (no `--apply`) — must report 0 drift.
4. Commit both copies. Touches list in PLAN-06 already names both paths per task.

Note: `tests/` and `docs/` are kit-source-only, NOT in the drift manifest. T7 (tests) and T8 (docs) edit only the orchestrator-kit copy.

### PR conventions
- Branch: `claude/plan-06-task-<N>`
- Title: `feat(dashboard): PLAN-06 T<N> — <short description>`
- Body: include local CI verification block + acceptance criteria table with evidence
- One task = one PR. No bundling.
- Operator merges; don't self-merge.

### Spec deviations are OK but log them

T2 deviated from the spec (state file vs run files; tokens vs $ headline) for sound technical reasons. Pattern to follow:
1. Note the deviation prominently in the PR body
2. Explain why (better engineering, captures more data, etc.)
3. Verify the original acceptance criteria still hold (or amend the plan)
4. Don't ask — Tier 2 decision per the worker prompt discipline

## Reference: file paths used in this work

| Purpose | Path |
|---|---|
| Spec | `orchestrator-kit/docs/SPEC-mission-centre.md` |
| Mockup (approved v2) | `orchestrator-kit/docs/mockups/mission-centre-unified.html` |
| Mockup (v1 board-only, comparison) | `orchestrator-kit/docs/mockups/mission-centre-mockup.html` |
| Plan | `.claude/plans/PLAN-06-mission-centre.md` |
| Plan state (gitignored) | `.claude/plans/PLAN-06-mission-centre.state.json` |
| T1 output | `*/dashboard/static/agents.json`, `blocked_jokes.json` |
| T2 output | `*/dashboard/api_costs.py` |
| Dashboard scripts dir (canonical) | `orchestrator-kit/.claude/scripts/dashboard/` |
| Dashboard scripts dir (root install) | `.claude/scripts/dashboard/` |
| Existing dashboard endpoint (legacy) | `app.py` route `/` (will move to `/dashboard` in T6) |

## How `claude -p` usage data flows (T2 reference)

For T3 and T4 you'll work with the same data source. The orchestrator captures usage via `_dispatcher_lib.sh:update_task_usage`, which jq-extracts from the run JSON and writes to:

```jsonc
state.tasks["<N>"].usage = {
  total_cost_usd: 0.42,
  total_input_tokens: 100000,
  total_output_tokens: 50000,
  // ...
  runs: [
    {
      kind: "worker" | "iterator" | "reviewer",
      cost_usd: 0.42,
      input_tokens: 100000, output_tokens: 50000,
      cache_read_input_tokens: 200000, cache_creation_input_tokens: 10000,
      num_turns: 12, duration_ms: 45000,
      model: "claude-opus-4-7",
      is_error: false,
      run_at: "2026-05-26T05:00:00+00:00"
    }
  ]
}
```

The state file is the canonical source. Don't walk `run-*.json` for cost — `review-pr.sh` doesn't even persist its output file.

## Prompt for the next session

> Continuing PLAN-06 Mission Centre implementation. T1 and T2 are merged on main. Read `orchestrator-kit/docs/HANDOFF-2026-05-26-mission-centre.md` first — it has the state, the spec deviations made so far, the local-verification protocol (GHA is degraded), the kit-drift discipline, and the next-task brief.
>
> Start T3: extend `api_workers.py` with a `last_log` field per worker. Acceptance criteria are in PLAN-06 T3. Follow the same PR pattern as T1/T2: implement on `claude/plan-06-task-3` branch, sync to root, run local CI, post evidence in PR body, wait for my merge call.
