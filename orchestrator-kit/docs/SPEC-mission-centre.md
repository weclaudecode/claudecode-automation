# SPEC: Mission Centre — unified kanban + telemetry view for the orchestrator dashboard

**Status:** Approved design (2026-05-26). Implementation plan to follow as
`PLAN-NN-mission-centre.md`.

**Companion docs:**
- `DASHBOARD.md` — current dashboard architecture (the surface this extends).
- `DASHBOARD-UX-REVIEW.md` — prior UX review of the existing panels.
- `SPEC-plan-authoring.md` — sibling spec format (same prose conventions).

**Visual reference:** `mockups/mission-centre-unified.html` — static
single-page HTML mockup committed to the repo. Open in a browser to see
the target layout, colors, card density, agent avatars, and the relative
sizing of each panel.

## Goal

A single Mission Centre page where the operator sees the active plan's
task board AND the supporting telemetry (workers, plan status, cost, live
log, recent events, GitHub) without switching tabs. The board is the
hero; everything else fills the space the board doesn't need.

The Mission Centre is "where a developer opens to see what the
orchestrator is doing right now and what it needs from them" — kanban
position for workflow state, named agents for emotional engagement, live
log for "what's happening this second", cost for "what is this
costing me".

## Non-goals (v1)

- **No drag-and-drop, no per-card action buttons.** Read-only mirror only.
  State changes happen via the orchestrator (cron / routine / `/loop`) and
  the page re-renders. This avoids writing to `state.json` from the browser
  (which would collide with worker locks) and prevents the operator from
  forcing the FSM into illegal positions.
- **No filter / search / focus mode.** Deliberately deferred. The Todo
  column scrolls if it grows past ~6 cards; every other column caps in
  practice around 5 cards.
- **No multi-project support.** Single project per dashboard instance.
- **No browser-side authentication.** Loopback-only, like today's dashboard.
  SSH-tunnel for remote.
- **No mobile / touch layout.** Desktop only (≥1000px viewport).

## User journey

1. Operator runs `./.claude/scripts/dashboard.sh start` (existing command,
   unchanged).
2. Opens `http://127.0.0.1:5174/` and lands directly on the **Mission
   Centre** (this is the new default landing page). A nav tab labelled
   "Dashboard (legacy)" still exists for the operator who wants the prior
   6-panel layout.
3. Sees the full-width Mission Centre: top nav, optional alerts strip,
   then the unified grid (board left, right rail of supporting panels,
   live log below the board, activity + GitHub at the bottom).
4. Glances at the In Progress column — sees named bot avatars (Pip,
   Bento, Nova...) on the cards actively being worked. Glances at the
   right rail Active Workers panel — sees the same agents in detail
   (full PID, elapsed time, last log line).
5. Watches the live log auto-scroll as the next tick fires. New events
   land in the Activity panel. Done cards accumulate cost badges.
6. Clicks any card → opens its GH PR (or issue if no PR yet) in a new tab.
7. The page polls `/api/board` every 5 seconds and re-renders.

## Architecture

```
Browser (board.html + board.js + board.css)
        │ poll every 5 s
        ▼
Flask /api/board   ──>   composes a unified payload:
        │                    {board: {…7 columns…},
        │                     workers: [active workers + last log line],
        │                     plan_status: {merged, in_progress, pending, blocked},
        │                     cost: {today, breakdown, trend},
        │                     log_tail: [last 40 lines, parsed],
        │                     activity: [last 20 events.jsonl entries],
        │                     github: {issues, prs},
        │                     errors: [partial-source failures]}
        │
        ├─ reads .claude/plans/*.state.json (active + archived)
        ├─ reads .claude/state/events.jsonl (activity + cost rollup)
        ├─ reads .claude/state/orchestrator.log (live log tail)
        ├─ reads .claude/state/active_worktrees.txt (worker→task)
        ├─ reads .claude/state/run-*.json (last log line per worker)
        ├─ gh issue/PR list (reuse existing 30 s cache in api_github.py)
        └─ static lookups: agents.json (name pool), blocked_jokes.json
```

The endpoint is a composition over data sources that already exist (or
were added in PR #43). No new persistent state on disk. The agent name
pool, the joke pool, and the price table ship as static files inside
`dashboard/`.

One unified endpoint (rather than separate endpoints per panel) was
chosen so the operator sees a consistent snapshot across all panels at
every poll — no risk of the board showing "in_review" while the workers
panel still shows the worker as alive. The payload is small (<50 KB
realistic max) so polling cost is fine.

## Page layout

```
┌─ Nav: Mission Centre  |  Dashboard (legacy)              live · tick · plan ┐
├─ Alerts strip (auto-shown when there are alerts) ──────────────────────────┤
├─────────────────────────────────────────────────────┬──────────────────────┤
│                                                       │  ACTIVE WORKERS      │
│  TASK BOARD                                          │  (avatars 36px,      │
│  ┌──────┬─────┬──────┬─────┬─────┬──────┬─────┐    │   PID, elapsed,      │
│  │Backlg│Todo │InProg│Ready│InRev│Block │ Done│    │   wt-path, last log) │
│  │  2   │  7  │  2   │  1  │  2  │  2   │  3  │    │                      │
│  │ ▢▢  │ ▢▢▢ │ ▢▢   │ ▢   │ ▢▢ │ ▢▢   │ ▢▢▢ │    ├──────────────────────┤
│  │     │ ▢▢▢ │      │     │     │      │     │    │  PLAN STATUS         │
│  │     │ ▢⋮  │      │     │     │      │     │    │  (slug, % bar,       │
│  └──────┴─────┴──────┴─────┴─────┴──────┴─────┘    │   merged/run/pending/│
│  (Only Todo scrolls; others stay compact ≤5 cards)   │   blocked counts)    │
├─────────────────────────────────────────────────────┤                      │
│  LIVE LOG (orchestrator.log tail, auto-scroll)       │  COST (today)        │
│  Tick boundaries highlighted, phase headers, warn,   │  Big $ number,       │
│  err, ok lines color-coded.                          │  breakdown by role,  │
│                                                       │  trend vs yesterday  │
├──────────────────────────┬──────────────────────────┤                      │
│  RECENT ACTIVITY         │  GITHUB                  │                      │
│  events.jsonl events,    │  Compact issue+PR list   │                      │
│  newest first, with      │  with CI status dots     │                      │
│  kind + detail per row.  │  (existing source).      │                      │
└──────────────────────────┴──────────────────────────┴──────────────────────┘
```

Grid:

```css
.main {
  display: grid;
  grid-template-columns: 1fr 320px;     /* main + right rail */
  grid-template-rows: auto auto auto;   /* board | log | bottom-row */
  gap: 12px;
  padding: 12px;
  /* NO max-width — fills viewport */
}
.right-rail { grid-row: 1 / 4; }        /* spans all 3 rows */
.bottom-row { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
```

At <1000 px viewport the right rail collapses below the board (single
column). At <600 px the layout degrades further but is not a v1 target.

## Component breakdown

| Component | Purpose | Depends on |
|-----------|---------|------------|
| `dashboard/api_board.py` | `GET /api/board`. Reads all data sources, composes unified payload. | `api_plan`, `api_workers`, `api_github`, `api_logs`, `api_costs` |
| `dashboard/api_costs.py` | Sums `usage.total_tokens × model_rate` across all `run-N-r*.json` and `review-N-r*.json` files for a task. In-memory cache keyed by (plan, task, mtime). Also exposes `cost_today()` helper for the right-rail Cost panel. | `.claude/state/*.json`, hardcoded price table |
| `dashboard/templates/board.html` | New default landing template. Top nav with "Mission Centre" (active) and "Dashboard (legacy)". Unified grid below. | `static/board.css`, `static/board.js` |
| `dashboard/static/board.js` | Polls `/api/board` every 5 s. Renders board, workers, plan status, cost, log, activity, github. Plain JS — no framework. | DOM only |
| `dashboard/static/board.css` | Grid layout, panel chrome, card styling, color tokens. Theme matches existing dashboard (dark, GitHub-like palette). | — |
| `dashboard/static/agents.json` | Curated pool of 20 worker character names + DiceBear seed strings. One entry tagged `role: reviewer` (Argus). | — |
| `dashboard/static/blocked_jokes.json` | ~20 one-liners for the Blocked column. | — |
| `dashboard/app.py` | Route changes: `/` now serves Mission Centre (`board.html`); existing 6-panel view moves to `/dashboard` for backward-compat. Register `api_board` and `api_costs` blueprints. | existing |

Each unit has one purpose, defined interface (JSON over HTTP for the API
surfaces, function arguments for helpers), and can be understood and
tested without reading the others.

## Column mapping

Pure function in `api_board.py`. Inputs:
`(active_state_files, archived_state_files, gh_issues, gh_prs, active_worktrees, pr_reviews)`.

| Column | Source rule |
|--------|-------------|
| **Backlog** | Open GH issues with label `monitor:finding` (one card per issue). Plus plans archived with `status: blocked` due to unmet `requires:` — one card per archived plan, not per task. Card title is the plan slug; `click_url` opens the plan file on GitHub. |
| **Todo** | Tasks with `status: pending` across all active plans. This is the only column that scrolls (max-height ~360 px). |
| **In Progress** | Tasks with `status: in_progress`. Active worktree manifest supplies the worker PID. Card avatar = per-task agent (see Agent identity). |
| **Ready For Review** | Tasks with `status: in_review` whose PR is open AND has no review verdict on the current HEAD SHA yet (no `orch:review-sha:<HEAD>` label). |
| **In Review** | Tasks with `status: in_review` whose PR is open AND has `orch:review-sha:<HEAD>` AND either `orch:review-blocked` label OR a running iterator. Badge: `iter rN/5` when iterator is active, `N blockers` when waiting on iterator. |
| **Blocked** | Tasks with `status: blocked` PLUS in-review tasks where `auto_merge_overrides[N] == false` and the PR carries `orch:needs-robbie` (sensitive flag). Joke shown. |
| **Done** | Tasks with `status: merged`. Cost badge shown. |

A task appears in exactly one column. The order above is precedence:
sensitive-in-review tasks land in Blocked, not In Review.

## Card schema

```jsonc
{
  "plan": "PLAN-05",
  "task": 3,
  "title": "Add receipt-sender Lambda",
  "depends_on": [1, 2],
  "issue": 41,
  "pr": 142,
  "click_url": "https://github.com/…/pull/142",
  "status": "in_progress",
  "sensitive": false,
  "agent": {
    "name": "Pip",
    "avatar_seed": "Pip",
    "role": "worker"                    // see role mapping below
  },
  "badges": ["14m"],                    // 0..N small pills
  "cost_usd": 0.42,                     // Done cards only
  "joke": "404: human-in-the-loop not found.",  // Blocked cards only
  "blocked_reason": "needs-robbie"      // Blocked cards only
}
```

Frontend treats every field as optional and renders defensively.

## Card rendering (compact, ≤2 lines tall in board view)

```
┌────────────────────────────────────┐
│ 🤖 Add receipt-sender Lambda       │  ← avatar (18px) + title
│ P-05  T2          14m              │  ← plan pill + task ID + badge
└────────────────────────────────────┘
```

Click anywhere on the card → opens `click_url` in a new tab. Hover →
tooltip with raw FSM status for introspection. Cards in non-board panels
(Active Workers) use 36px avatars with more detail per row.

## Agent identity

Three character classes:

1. **Workers / iterators** — pool of exactly 20 one-word, easy-to-say,
   playful names. Initial roster (final list owned by the implementation
   plan):

   > Pip · Bento · Nova · Echo · Glitch · Bug · Mochi · Cosmo · Pixel · Spark ·
   > Tofu · Otter · Pepper · Patch · Loop · Snap · Tweak · Zog · Boop · Comet

   Mapping: `agent_index = hash(plan_slug + ":" + task_num) % pool_size`.
   Deterministic — task 3 of PLAN-05 is always the same character across
   retries, iterations, and dashboard restarts. Operator builds memory.

2. **Reviewer** — single fixed character: **Argus**. Renders on every In
   Review card that's awaiting reviewer verdict (the "Argus is looking at
   this" signal). When the iterator picks up after review-blocked, the
   card swaps to the worker's per-task agent.

3. **Avatars** — DiceBear v8 `bottts` style (chunky robot bots, sharp
   saturated colors, geometric faces). URL pattern:
   `https://api.dicebear.com/8.x/bottts/svg?seed=<name>&backgroundType=gradientLinear`.

   Argus gets a fixed pink background (`backgroundColor=db61a2`) so it's
   visually distinct from worker bots without changing style.

   **Fallback** if DiceBear is unreachable: client-side initials-on-color
   SVG generated from the seed. Documented in DASHBOARD.md.

### Agent role per column

| Column | role | Character |
|--------|------|-----------|
| Backlog | `null` | None (issue/plan icon instead) |
| Todo | `null` | None (deps shown instead) |
| In Progress | `worker` | Per-task character from pool |
| Ready For Review | `worker` | Same per-task character (just finished) |
| In Review (awaiting reviewer) | `reviewer` | Argus (fixed) |
| In Review (iterating) | `iterator` | Same per-task character (iterator inherits) |
| Blocked | `worker` | Per-task character + joke pill |
| Done | `null` | Per-task character muted (passenger) |

## Blocked-card jokes

`dashboard/static/blocked_jokes.json` — array of ~20 one-liners. Tone:
self-deprecating about the agent ("I tried. Brain too small. Send
human."), or affectionate about humans ("404: human-in-the-loop not
found."). Rotates by `hash(plan_slug + ":" + task_num + ":" + utc_date)
% pool_size` so the same blocked task shows the same joke today but
something different tomorrow — keeps the page from feeling stale.

## Active Workers panel (right rail)

For each task in `status: in_progress` (or with a running iterator),
render one detail row with 36 px avatar:

```
┌────────────────────────────────────────────┐
│  🤖  Pip                                    │
│      T2 · PLAN-05 · Add receipt-sender …   │
│      worker · pid 41832 · 14m · wt-plan05-t2 │
│      > tests_run="pytest" → 12 passed       │
└────────────────────────────────────────────┘
```

Source: `active_worktrees.txt` joined with `ps` for PIDs (existing
api_workers logic), plus a tail of the worker's `run-<task>-r<retry>.json`
for the last log line. The last-log line is best-effort: if the run file
isn't yet written or is unparseable, omit that line rather than fail.

## Plan Status panel (right rail)

Compact summary of the active plan:

```
PLAN-05-aws-deploy-support
████████░░  50% complete    (3 of 6 merged)
✓ merged       3
▶ in progress  2
◯ pending      1
⚠ blocked      0
```

When multiple plans are active, render one Plan Status block per plan
stacked vertically (rare today; common in multi-env futures).

## Cost panel (right rail)

```
        $2.18
workers           $1.42
reviewer (Argus)  $0.62
iterator          $0.14

↑ 23% vs yesterday · $3.71 this week
```

- **Today** = sum of `usage.total_tokens × model_rate` over events
  emitted today.
- **Breakdown** = same sum split by `agent.role` (worker / reviewer / iterator).
- **Trend** = today vs yesterday (UTC days). Weekly = trailing 7 days.

Cost data is computed in `api_costs.py`:

- **Data source:** `.claude/state/run-<task>-r<retry>.json`,
  `.claude/state/review-<task>-r<retry>.json` — the existing `claude -p
  --output-format json` outputs.
- **Pricing table:** hardcoded in `api_costs.py` with a snapshot date
  comment. Sourced from `https://www.anthropic.com/pricing` at
  implementation time.
- **Cache:** in-memory dict keyed by `(plan, task, retry, mtime)`.
- **Per-task cost** also persisted on `task_merged` events.jsonl emission
  (extras: `cost_usd`) so historical reads don't have to walk run files.

## Live Log panel

Tail of `.claude/state/orchestrator.log`, last ~40 lines, color-coded:

| Line pattern | Color |
|--------------|-------|
| `=== tick <iso> ===` | Blue (tick boundary) |
| `--- phase N: ... ---` | Purple (phase boundary) |
| `warning:` | Amber |
| `error:` | Red |
| trailing `→ <result>` | Green for ok |

Auto-scrolls to the bottom unless the operator scrolls up (same behavior
as the existing Logs panel). 240 px tall by default.

## Recent Activity panel

Reads `.claude/state/events.jsonl`, last 20 entries reversed (newest
first):

```
10:36:44  task_in_review
          T2 (Pip) → PR #147 · auto_merge:true

10:31:48  tick_done
          14 tasks · pending:7 in_progress:2 in_review:3 blocked:2 merged:3

10:15:03  task_merged
          T0a (Mochi) → PR #140 · cost $0.31
```

Event kind colored by type (`task_merged` green, `task_blocked` red,
`review` pink). Detail line synthesized from the event's `extras` dict
according to a per-kind formatter; unknown kinds render as `kind:
{json}` so a future event type doesn't crash the panel.

## GitHub panel

Compact two-section list using existing `api_github.py` (30 s cache).
Issues first (most recent 5), then PRs (most recent 5). Each PR row
shows CI status dot (●/◐/—) like the existing panel. Click → opens
GH in a new tab.

Smaller than the existing dashboard's GitHub panel because most of this
info now duplicates the board's PR/issue links — kept for the CI dot
signal and for issues without plan tasks.

## API surface

### `GET /api/board`

```json
{
  "as_of": "2026-05-26T10:00:00Z",
  "board": {
    "backlog":          [card, ...],
    "todo":             [card, ...],
    "in_progress":      [card, ...],
    "ready_for_review": [card, ...],
    "in_review":        [card, ...],
    "blocked":          [card, ...],
    "done":             [card, ...]
  },
  "workers": [
    {"name": "Pip", "avatar_seed": "Pip", "task": 2, "plan": "PLAN-05",
     "title": "Add receipt-sender Lambda", "pid": 41832,
     "elapsed_sec": 840, "worktree": "wt-plan05-t2/",
     "last_log": "tests_run=\"pytest\" → 12 passed", "role": "worker"}
  ],
  "plan_status": [
    {"plan": "PLAN-05", "slug": "PLAN-05-aws-deploy-support",
     "merged": 3, "in_progress": 2, "pending": 1, "blocked": 0, "total": 6}
  ],
  "cost": {
    "today_usd": 2.18,
    "by_role": {"worker": 1.42, "reviewer": 0.62, "iterator": 0.14},
    "yesterday_usd": 1.77,
    "this_week_usd": 3.71
  },
  "log_tail": [
    {"ts": "10:31:42", "text": "=== tick 2026-05-26T10:31:42Z ===", "kind": "tick"},
    {"ts": "10:31:43", "text": "--- phase 1: refresh-deps ---", "kind": "phase"},
    ...
  ],
  "activity": [
    {"ts": "10:36:44", "kind": "task_in_review",
     "detail": "T2 (Pip) → PR #147 · auto_merge:true"},
    ...
  ],
  "github": {
    "issues": [{"num": 14, "title": "...", "labels": ["monitor:finding"]}],
    "prs":    [{"num": 147, "title": "...", "ci_state": "PENDING"}]
  },
  "errors": []
}
```

`errors` non-empty when a partial source fails (gh timed out, state file
unreadable). Affected panels render a small "data unavailable" banner;
other panels still work.

## File layout

```
orchestrator-kit/.claude/scripts/dashboard/
├── app.py                          # route changes: / serves Mission Centre, /dashboard serves legacy
├── api_board.py                    # NEW — unified payload composer
├── api_costs.py                    # NEW — token→USD rollup
├── api_plan.py                     # unchanged
├── api_workers.py                  # extended: emits last_log line per worker
├── api_github.py                   # unchanged
├── api_logs.py                     # unchanged
├── templates/
│   ├── index.html                  # legacy 6-panel view (now served at /dashboard)
│   └── board.html                  # NEW — Mission Centre landing template
└── static/
    ├── (existing assets)           # unchanged
    ├── board.js                    # NEW
    ├── board.css                   # NEW
    ├── agents.json                 # NEW (20 worker names + Argus)
    └── blocked_jokes.json          # NEW (~20 lines)

orchestrator-kit/tests/
└── _test_board_api.sh              # NEW
```

Also updates:

- `orchestrator-kit/docs/DASHBOARD.md` — adds a "Mission Centre" section
  with the unified layout description and a screenshot from the mockup.
  Notes that `/dashboard` still serves the legacy panels.
- `orchestrator-kit/README.md` — updates the "Local dashboard" pointer
  to mention the Mission Centre as the default landing page.

Drift CI passes automatically because all new files live under
`.claude/scripts/dashboard/` which is in the kit-owned manifest.

## Testing

`_test_board_api.sh` exercises the column-builder and cost-rollup pure
functions with synthetic inputs:

| Scenario | Asserts |
|----------|---------|
| Empty inputs | All 7 columns empty; `errors` empty; cost = $0. |
| One task per FSM status | Each task lands in the expected column. |
| Sensitive in-review with `orch:needs-robbie` | Lands in Blocked, not In Review. |
| Iterator running on review-blocked PR | Lands in In Review with `iter rN/5` badge. |
| Monitor finding issue | Lands in Backlog with `click_url` pointing to the issue. |
| Done card with run files | `cost_usd` is a positive number summing all retries. |
| Done card without run files | `cost_usd` is null (renders as "—" client-side). |
| Two tasks across two plans | Both render with their respective plan pills. |
| Partial GH outage | Affected panels have an `errors` entry; other panels still render. |
| `hash(plan + task) → agent` deterministic | Same input → same agent name across multiple invocations. |
| Argus assignment | Reviewer role always returns `Argus` regardless of task. |

No browser test in v1. The rendering layer is small enough to eyeball
during development.

## Risks

| Risk | Mitigation |
|------|------------|
| DiceBear network dependency | Client-side initials-on-color SVG fallback. Documented. |
| Pricing table drifts when Anthropic changes prices | Versioned in-file with a snapshot date. Old tasks render with old prices (correct). README notes how to refresh. |
| Cost computation is expensive (many run files) | mtime-keyed in-memory cache; pre-computed per-task cost persisted on `task_merged` event for historical reads. |
| Column mapping accumulates edge cases | All logic in one pure function with the test matrix above. |
| `/` redirect surprises existing operators | Legacy 6-panel view remains accessible at `/dashboard`. README and CHANGELOG note the redirect. |
| Operator confusion if a task is in an unexpected column | Tooltip on hover surfaces the raw FSM status. |

## Out of scope for v1 (tracked for future)

- Filter / search / focus mode
- Drag-and-drop or quick-action buttons
- Multi-project view (one dashboard per project for now)
- Real-time updates via SSE / WebSocket (5 s polling is fine)
- Mobile / touch layout
- Theme switching (light/dark)
- Cost-budget alerts (card lights up when its cost exceeds a threshold)
- Aggregate views (cost-per-plan, agent leaderboard, mean-time-to-merge)
- Custom agent name pools (operator-editable)

## Open questions resolved

| Question | Decision |
|----------|----------|
| New view vs replace existing | Mission Centre at `/`, legacy panels at `/dashboard` |
| Combine board + telemetry on one page | Yes — unified Mission Centre |
| Ready For Review vs In Review split | By review stage (PR pushed, no review verdict on current SHA) |
| Iterator-working location | In Review column with `iter rN/5` badge; card uses worker's per-task agent |
| Backlog scope | Monitor findings + archived blocked-on-upstream plans |
| Agent name pool | One-word, easy-to-say, playful names (initial roster of 20 in spec) |
| Agent avatars | DiceBear `bottts` (sharp colors, geometric bot faces) with initials-SVG fallback |
| Reviewer character | Fixed "Argus" with pink background tint |
| Interactivity | Read-only mirror + click-through only |
| Page width | Full viewport (no max-width centering) |
| Active Workers placement | Right rail (320 px), spans all rows |
| Cost panel | Right rail, breakdown by role, today vs yesterday trend |
| Live log placement | Below board, full width of main column |
| Activity stream | Bottom-left, alongside compact GitHub panel |
