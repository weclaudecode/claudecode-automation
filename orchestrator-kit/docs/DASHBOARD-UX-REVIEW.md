# Dashboard UX Review + Improvement Plan

Reviewer: UI/UX designer perspective.
Date: 2026-05-24.
Subject: `orchestrator-kit/.claude/scripts/dashboard/` — the local Flask
operator dashboard shipped in PR #23.

This document evaluates the dashboard against three lenses: (1) heuristic
usability, (2) coverage — does the UI surface every system capability
that an operator needs, (3) workflow fitness — can an operator manage
tasks and troubleshoot issues without leaving the dashboard. It then
proposes a prioritised improvement plan.

The architecture is sound; the gaps are almost entirely in the
**presentation, discoverability, and operator-workflow** layer, not in
the backend.

---

## 1. Executive summary

| Rating              | Score | Notes                                                                                                                              |
|---------------------|-------|------------------------------------------------------------------------------------------------------------------------------------|
| Architecture        | 8/10  | Envelope contract, per-panel isolation, blueprint auto-discovery, localhost-only enforcement, redaction — all well done.            |
| Visual hierarchy    | 5/10  | Five equally-weighted panels in a 3×2 grid; logs (the primary troubleshooting surface) is no bigger than the static config panel.   |
| Feature coverage    | 5/10  | Five of the kit's seven major capabilities (monitor, decisions log, plan-authoring, tick health, cost trend, FSM context) are absent or buried. |
| Discoverability     | 3/10  | No tooltips, no legends, no per-column help, no docs links, no keyboard shortcuts. An operator new to the kit cannot self-orient.  |
| Task management     | 4/10  | Plan table is read-only flat list. No filter, no sort, no row-detail expand, no "what should I do next" affordance.                |
| Troubleshooting     | 4/10  | Logs are tailed but unfilterable, unsearchable, and the dashboard never tells you when the orchestrator itself is unhealthy.       |
| Accessibility       | 4/10  | Status colour without text affordance; 12–13px monospace throughout; no focus styles; no aria-live for log/status updates.         |

Top three changes that would move the needle hardest:

1. **Add a top-of-page "operator alerts" strip** that surfaces monitor
   findings, stale-plan warnings, dead-orchestrator detection, and
   needs-robbie PRs as actionable cards. This is the single change that
   turns the dashboard from "passive readout" into "operator console."
2. **Reorganise the grid into a primary/secondary layout** — logs +
   plan-task table get 70% of the viewport; workers/config/github move
   to a narrower secondary column. Match panel size to operator focus
   time.
3. **Add a "what now?" affordance to every error and blocked state** —
   a help icon next to `blocked`, `worker_failed_3x`, fetch errors,
   etc., that pops the relevant runbook snippet inline.

---

## 2. What works well (preserve these)

The dashboard makes good engineering decisions that the redesign must
preserve:

- **Per-panel error isolation.** One endpoint failing shows a per-panel
  red banner instead of a blank screen. Keep this contract.
- **Polling pause + per-panel refresh.** Stops the operator from
  fighting the auto-refresh while reading.
- **HTML escaping discipline.** Every dynamic value goes through
  `esc()` before insertion. Lint-grep-friendly — keep the single
  `setHTML` callsite pattern.
- **Localhost-only hard enforcement.** `create_app()` raises on
  non-loopback host; `dashboard.sh` won't pass anything else. Keep.
- **Secret redaction in worker cmdlines.** Over-broad on purpose. Keep
  and extend (see §6).
- **Blueprint auto-discovery.** Adding a new endpoint is just dropping
  a file. Preserve this when adding the new panels recommended below.
- **Stale-data timestamp per panel.** Already there; just needs to be
  louder when staleness crosses a threshold.

---

## 3. Heuristic evaluation (Nielsen's 10)

| # | Heuristic                                | Verdict | Evidence                                                                                                  |
|---|------------------------------------------|---------|-----------------------------------------------------------------------------------------------------------|
| 1 | Visibility of system status              | Weak    | Polling status text is the only heartbeat. No tick-completed indicator, no dead-orchestrator detection.   |
| 2 | Match between system & real world        | OK      | Phase/tick/task vocabulary matches the codebase — operator-facing not bot-facing.                          |
| 3 | User control & freedom                   | Weak    | No undo, no filter, no "show me only blocked", no per-panel expand-to-fullscreen.                          |
| 4 | Consistency & standards                  | Strong  | Status badges, envelope format, table layouts are uniform.                                                 |
| 5 | Error prevention                         | Weak    | No confirmation needed because no actions exist — but no validation of `lines=` query input either.        |
| 6 | Recognition rather than recall           | Weak    | Operator must remember what `deps`, `touches`, `retries`, `orch:needs-robbie`, `safety_block` mean.        |
| 7 | Flexibility & efficiency                 | Weak    | No keyboard shortcuts. No saved views. Same UI for first-time user and someone running the loop hourly.    |
| 8 | Aesthetic & minimalist design            | Strong  | Dark monospace, minimal chrome, low decoration — fits the audience.                                        |
| 9 | Help users recognise/recover from errors | Weak    | "fetch failed: HTTP 500" with no remediation hint. Blocked tasks don't show how to unblock.                |
| 10 | Help & documentation                    | Missing | Zero in-app help. No link to DASHBOARD.md, no "?" icon, no tour, no inline runbook snippets.               |

---

## 4. Feature coverage matrix

Maps every kit capability to whether the dashboard surfaces it.

| Kit capability                                | In dashboard?   | Where / gap                                                                                          |
|-----------------------------------------------|-----------------|------------------------------------------------------------------------------------------------------|
| Plan-level status (status, tasks, ingested)   | ✅ Good          | Plan panel.                                                                                          |
| Per-task FSM (pending → … → merged/blocked)   | ⚠️ Partial      | Status badge shown, but no FSM-context (what state can it go to next? what causes the transition?). |
| Per-task usage (cost, tokens, turns, time)    | ✅ Good          | Plan panel compact `$$$ · Nt · Xs` cell.                                                             |
| Plan-level cost rollup                        | ✅ Good          | Plan panel KV block.                                                                                 |
| Cost trend over time (per day / per tick)     | ❌ Missing       | No history view. Operator can't tell if today's burn is unusual.                                     |
| Live orchestrator log (tail)                  | ✅ Good          | Logs panel.                                                                                          |
| Log filter / search / level filter            | ❌ Missing       | Last 200 lines only; no filter; no search.                                                           |
| Tick boundary navigation                      | ⚠️ Partial      | Tick lines highlighted; not jumpable.                                                                |
| Phase-level status (which phase ran last?)    | ❌ Missing       | Operator has to read raw log lines.                                                                  |
| Active claude workers (PID, runtime, cmd)    | ⚠️ Partial      | PID + cmd shown; **no elapsed time**, no task-correlation column.                                    |
| Active worktrees                              | ✅ Good          | Workers panel second table.                                                                          |
| Worktree ↔ worker join                        | ❌ Missing       | Two separate tables; operator has to mentally join by PID/path.                                      |
| GitHub open issues                            | ✅ Good          | Issues panel.                                                                                        |
| GitHub recent PRs                             | ✅ Good          | PRs panel.                                                                                           |
| CI status per PR                              | ❌ Missing       | PR state shown but no green/red CI dot.                                                              |
| **Monitor findings (H1–H7)**                  | ❌ Buried        | Labelled `monitor:finding`, shows in Issues list with no special treatment. Should be top-of-page.  |
| Dead-orchestrator detection                   | ❌ Missing       | If cron stops firing, dashboard cheerfully keeps showing yesterday's tick.                           |
| Lock holder info                              | ❌ Missing       | `.claude/state/orchestrator.lock/` contains a PID; never shown.                                      |
| Effective config (env, settings, plan state)  | ✅ Good          | Config panel.                                                                                        |
| `auto_merge_overrides` highlight              | ⚠️ Partial      | Surfaced as plain rows; not visually grouped or warning-tinted.                                      |
| `decisions.md` tail                           | ❌ Missing       | Critical context for understanding worker behaviour; absent from UI.                                 |
| `orch:needs-robbie` PR queue (sensitive holds)| ❌ Buried        | One row among PRs; should be its own actionable strip.                                               |
| Cascade-blocked tasks                         | ⚠️ Partial      | `blocked_reason: upstream_blocked_t<N>` shown as red text; no graph view of the cascade.            |
| Plan archive history                          | ❌ Missing       | Only current plan visible; no "previous plans" navigator.                                            |
| Plan-authoring helpers (`/plan-format`)       | ❌ Missing       | No link or guidance for the operator to create a new plan.                                           |
| Kit-upgrade drift detection                   | ❌ Missing       | No surface for `kit-upgrade.sh` status.                                                              |
| Dashboard's own health                        | ❌ Missing       | `/api/healthz` exists but the frontend never visits it; loss of connection is silent.                |

**Score: 8 ✅ / 6 ⚠️ / 13 ❌ across 27 capabilities — ~50% surfaced.**

---

## 5. Critical workflow gaps

Three operator workflows the dashboard should make easy and currently
doesn't:

### Workflow A — "Something's wrong, what should I do?"

**Current path:** Operator opens dashboard → scans 5 panels equally
weighted → maybe notices a red badge → reads the blocked_reason →
opens README → searches for the reason string → finds the
"Resuming a blocked plan" jq commands → copy-pastes.

**Desired path:** Operator opens dashboard → top strip shows "1 task
blocked, 2 PRs need attention, 1 monitor finding" with the most urgent
expanded inline → click to expand → see exact remediation commands +
runbook link.

### Workflow B — "Did the latest tick complete cleanly?"

**Current path:** Operator opens logs panel → scrolls (it's 200 lines,
might require scrolling up) → finds the last `=== tick ... ===` marker
→ checks subsequent phase lines for errors → cross-references workers
panel for residual processes.

**Desired path:** Operator opens dashboard → "Last tick" card shows
`✔ tick 2026-05-24T03:15:00Z · 4 phases ran · 0 errors · 2 workers
launched · 1 PR merged` with click-through to that tick's log slice.

### Workflow C — "Why is task N taking so long?"

**Current path:** Read task row in plan panel → memorise PR number →
switch to Issues+PRs panel → click PR link → leave dashboard → check
PR commits → return → check workers panel for matching PID → check
logs panel for relevant tick.

**Desired path:** Click task row in plan panel → side drawer opens
showing: full state JSON, last 50 log lines mentioning task N, owning
worker PID + elapsed time, PR with CI status, "open PR" link, "kill
worker" guidance, blocked_reason explanation if applicable.

---

## 6. Detailed improvement plan

Grouped by theme and prioritised. Each item lists scope, value, and
rough effort (S/M/L).

### Tier 1 — Critical (do first)

#### 1.1 Add an "operator alerts" top strip
- **Scope:** New panel above the grid; promotes urgent items from
  monitor findings + needs-robbie PRs + blocked tasks + dead-orchestrator
  detection into one always-visible row.
- **Value:** Turns dashboard from passive readout to operator console.
- **Effort:** M (new endpoint that joins issues/PRs/plan-state; new
  frontend section).

#### 1.2 Add dead-orchestrator detection
- **Scope:** Compute `now - last_tick_completed_ts` from logs;
  if > 2× expected cron interval, show a red banner.
- **Value:** Surfaces the silent failure mode that costs the most
  operator time (cron stopped firing).
- **Effort:** S (extend `/api/logs` or new `/api/health`).

#### 1.3 Show CI status on every PR row
- **Scope:** `gh pr list --json statusCheckRollup` exposes a single
  `state` per PR (`SUCCESS`/`FAILURE`/`PENDING`/`null`). Render as a
  dot before the PR title.
- **Value:** Removes a click out to GitHub for every "is it green yet?"
  question.
- **Effort:** S.

#### 1.4 Promote monitor findings out of "Issues" list
- **Scope:** Filter `monitor:finding`-labelled issues into a dedicated
  "Monitor" sub-section (or into the alerts strip).
- **Value:** H1–H7 alerts only matter if seen; currently lost in the
  general issues list.
- **Effort:** S.

#### 1.5 Per-error remediation hints
- **Scope:** When a panel shows `fetch failed: gh CLI not found`, add a
  one-line fix. When a task shows `blocked_reason: worker_failed_3x`,
  add a help icon that pops `cat <<RUNBOOK …` snippet inline.
- **Value:** Closes the loop between symptom and fix without leaving
  the dashboard.
- **Effort:** M (a small `RUNBOOK` map in JS; consistent help icon).

### Tier 2 — High value (do next)

#### 2.1 Task row → side drawer
- **Scope:** Clicking a row in the plan table opens a side drawer
  with: full task state, log slice (filtered to lines mentioning
  task N or its branch/PR), owning worker PID + elapsed, PR card with
  CI status, "what now?" runbook for the current state.
- **Value:** Solves workflow C in one click.
- **Effort:** L (frontend modal + cross-endpoint join).

#### 2.2 Log filter + search
- **Scope:** Inline filter bar above the logs panel: text search,
  level filter chips (info/warn/error), tick range. The tail itself
  stays as-is.
- **Value:** Logs become useful at scale, not just for the latest 200
  lines.
- **Effort:** M (frontend; `/api/logs` already accepts `since` and
  `include_rotated`).

#### 2.3 Layout rebalance — primary/secondary
- **Scope:** Two-column layout: left 65% (plan table + logs stacked),
  right 35% (workers + github + config tabbed). Single full-width
  alerts strip above.
- **Value:** Matches operator focus time. Logs and plan are 80% of
  what operators look at; workers/config are reference.
- **Effort:** M (CSS + tabbed right column).

#### 2.4 Decisions log tail
- **Scope:** New panel (or tab in the right column) showing the last
  N entries from `.claude/state/decisions.md`. Markdown-rendered, not
  raw text.
- **Value:** Critical for understanding why a worker did what it did
  — especially when reviewing a failed run.
- **Effort:** M (new endpoint + simple markdown renderer or
  pre-formatted display).

#### 2.5 Tick health card
- **Scope:** Replace or supplement the header's `tick —` with a card
  showing: last tick start, last tick duration, phase summary, errors
  count, next expected tick (if cron schedule known).
- **Value:** Solves workflow B.
- **Effort:** M.

### Tier 3 — Polish + accessibility

#### 3.1 In-app help
- **Scope:** `?` icon top-right that opens an overlay with: keyboard
  shortcuts (r = refresh, p = pause, / = focus log search), glossary
  (status meanings, label meanings, blocked_reason codes), link out
  to DASHBOARD.md and the orchestrator README.
- **Value:** Self-service onboarding; reduces "what does this mean?"
  questions.
- **Effort:** S.

#### 3.2 Status badges add text + colour
- **Scope:** Add a leading single-char glyph to every status badge
  (e.g. `● merged`, `◷ in_review`, `■ blocked`). Colour stays.
- **Value:** Accessibility (colourblind) + scannability.
- **Effort:** S.

#### 3.3 Connection health
- **Scope:** Frontend hits `/api/healthz` every 10s; if it fails
  twice in a row, show a banner "Dashboard backend unreachable —
  is it running?" with the `dashboard.sh restart` hint.
- **Value:** Silences the "why isn't the data updating?" debugging
  loop.
- **Effort:** S.

#### 3.4 Aria-live for new log lines + status flips
- **Scope:** `aria-live="polite"` on the alerts strip and a hidden
  status region announcing flips like "task 3 → merged".
- **Value:** Screen-reader users + ambient workflows (operator alt-tabs
  away and gets a system notification on flip).
- **Effort:** S.

#### 3.5 Empty-state copy
- **Scope:** Replace bland empties (`no active plan`, `none`) with
  contextual guidance:
  - "No active plan — drop one in `.claude/plans/` and run `ingest-plan.sh`"
  - "No workers — workers only run during ticks. Last tick: 03:15 UTC."
  - "No GitHub data — check `gh auth status`."
- **Value:** Self-onboarding.
- **Effort:** S.

#### 3.6 Plan-authoring shortcut
- **Scope:** Top-right link "Author a new plan" → opens DASHBOARD.md
  or a static help page documenting `/plan-format` and `plan-author`.
- **Value:** Discoverability of a major kit feature.
- **Effort:** S.

### Tier 4 — Nice-to-have

#### 4.1 Cost trajectory chart
- **Scope:** Sparkline of cost per tick over last 24h above the
  per-plan cost rollup.
- **Value:** Catches runaway spend early.
- **Effort:** M.

#### 4.2 Previous-plans navigator
- **Scope:** Dropdown listing archived plans; switching swaps the
  plan panel into read-only history view.
- **Value:** Post-mortem context.
- **Effort:** M.

#### 4.3 Cascade-block graph
- **Scope:** Tiny inline graph (Mermaid or just SVG) showing the
  dependency chain when a task is blocked with
  `upstream_blocked_t<N>`.
- **Value:** Makes cascade-block diagnosis instant.
- **Effort:** M.

#### 4.4 Kit-upgrade drift indicator
- **Scope:** Background `kit-upgrade.sh <canonical-source>` call (if
  the operator configured a source path); badge in header if drift.
- **Value:** Closes the loop with the new `kit-upgrade.sh` tool.
- **Effort:** M (operator opt-in; depends on configured source path).

---

## 7. Proposed layout (ASCII wireframes)

### 7.1 Header + alerts strip (new)

```
┌──────────────────────────────────────────────────────────────────────────┐
│ orchestrator  ·  PLAN-03 local-dashboard  ·  tick 03:15 UTC  ·  ⏸ pause │
├──────────────────────────────────────────────────────────────────────────┤
│ ⚠ ALERTS (3)                                                  collapse ▾ │
│  ■ task 7 BLOCKED · worker_failed_3x · [why?] [reset]   2h ago           │
│  ◷ PR #142 needs-robbie · sensitive merge · [open PR]   45m ago          │
│  ⓘ Monitor H3 fired · plan > 7d, 28% merged · #43       1d ago           │
└──────────────────────────────────────────────────────────────────────────┘
```

### 7.2 Primary/secondary grid (new)

```
┌────────────────────────────────────────────┬──────────────────────────────┐
│ PLAN STATUS                  ↻ refresh    │ [Workers][GitHub][Config]    │
│ status: in_progress · 5/7 done · $4.32    │ ─────────────────────────────│
│ ┌──────────────────────────────────────┐  │ workers (2 active)           │
│ │ # │ title           │ stat │ pr     │  │  ● claude -p · task 3 · 4m   │
│ │ 3 │ api_plan        │ ●m   │ #142   │  │  ● claude -p · task 5 · 1m   │
│ │ 5 │ api_workers     │ ◷rv  │ #145   │  │                              │
│ │ 7 │ docs reconcile  │ ■bk  │ —      │ ←│ click row → drawer           │
│ └──────────────────────────────────────┘  │                              │
│                                            │                              │
│ LOGS                  [search][warn][err]│                              │
│ ┌──────────────────────────────────────┐  │                              │
│ │ === tick 2026-05-24T03:15:00Z ===    │  │                              │
│ │ --- phase 5: launch-pass ---         │  │                              │
│ │ task 3 in_progress (claude/plan-…)   │  │                              │
│ │ task 5 in_progress (claude/plan-…)   │  │                              │
│ │ phase 7: monitor-sweep ok            │  │                              │
│ └──────────────────────────────────────┘  │                              │
└────────────────────────────────────────────┴──────────────────────────────┘
```

### 7.3 Task-row drawer (new)

```
┌──── task 7: docs reconcile ────────────────────────────── ✕ ┐
│ status: ■ BLOCKED (worker_failed_3x · since 2h ago)         │
│ deps: 3, 5 (both merged)   touches: docs/**                 │
│ retries: 3 / 3              max_turns: 30                   │
│ issue: #48   pr: —                                          │
│                                                             │
│ ▼ Why is this blocked?                                      │
│   The worker failed three times in a row. Worktree at       │
│   ../wt-plan03-t7/ is preserved for inspection.             │
│                                                             │
│ ▼ How to unblock                                            │
│   1. cd ../wt-plan03-t7 && look at the failure              │
│   2. Optionally fix the plan task spec                      │
│   3. jq '.tasks["7"].status = "pending"' ... see runbook    │
│   [copy runbook commands]                                   │
│                                                             │
│ ▼ Recent log for task 7 (12 lines)                          │
│   …                                                         │
│                                                             │
│ [Open issue #48 →]  [View worktree]  [Mark resolved manually]│
└─────────────────────────────────────────────────────────────┘
```

---

## 8. Implementation sequencing

The work decomposes into roughly four PRs that an operator can ship one
at a time without breaking the existing dashboard:

| PR | Scope                                                         | Tier   | Effort |
|----|---------------------------------------------------------------|--------|--------|
| 1  | Alerts strip + monitor promotion + dead-orchestrator + CI dot | T1     | M      |
| 2  | Layout rebalance + log filter + tick health card              | T2     | M      |
| 3  | Task-row drawer + decisions log + in-app help + a11y polish   | T2/T3  | L      |
| 4  | Cost trajectory + cascade graph + previous-plans + kit-drift  | T4     | M      |

Recommend PRs 1 and 2 land before any net-new feature work — they
materially change the operator experience and reduce the surface that
later PRs need to redesign.

---

## 9. Out of scope (intentionally)

These ideas came up during the review and are explicitly **not**
recommended:

- **Authentication / multi-user.** The dashboard is a single-operator
  localhost tool; adding auth would compromise the security model
  documented in DASHBOARD.md §"Security model" without serving a real
  use case.
- **Write actions (kill worker, reset task, merge PR).** The kit's
  safety model assumes mutations go through `gh` / shell / `jq` so
  they're auditable in shell history. The dashboard can *generate the
  commands*; it should not run them.
- **Live `gh` subscriptions / WebSockets.** 5s polling is enough for
  the operator's reaction time; WebSockets would add infrastructure
  for no real-world benefit.
- **A "production" theme.** Operators do not want a polished SaaS UI;
  the terminal aesthetic is correct. Polish the affordances, not the
  branding.

---

## 10. Next steps

If this plan is adopted:

1. Convert §6 Tier 1 into a `PLAN-04-dashboard-ux-tier-1.md` using the
   plan-author skill or `/plan-format`.
2. Land it via the orchestrator (or manually) — Tier 1 fits in 4–5
   tasks with clear `touches:` boundaries (alerts endpoint, frontend
   alerts strip, CI dot, monitor promotion, dead-orch detector).
3. Re-score §1 after Tier 1 lands and decide whether Tier 2 is still
   the right next investment.
