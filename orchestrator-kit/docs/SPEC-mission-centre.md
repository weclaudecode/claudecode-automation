# SPEC: Mission Centre — kanban board view for the orchestrator dashboard

**Status:** Approved design (2026-05-26). Implementation plan to follow as
`PLAN-NN-mission-centre.md`.

**Companion docs:**
- `DASHBOARD.md` — current dashboard architecture (the surface this extends).
- `DASHBOARD-UX-REVIEW.md` — prior UX review of the existing panels.
- `SPEC-plan-authoring.md` — sibling spec format (same prose conventions).

## Goal

Add a Trello/Jira-style kanban board view to the existing local dashboard so a
single operator can see, at a glance, every task across the active plan(s) in
seven workflow columns, with personality on each in-progress card and a
clickable path to the underlying GitHub issue or PR.

The board is a **Mission Centre** framing — the place a developer opens to see
"what is the orchestrator doing right now, and what does it need from me?"

## Non-goals (v1)

- **No drag-and-drop, no per-card action buttons.** Read-only mirror only.
  State changes happen via the orchestrator (cron / routine / `/loop`) and the
  board re-renders. This avoids writing to `state.json` from the browser
  (which would collide with worker locks) and prevents the operator from
  forcing the FSM into illegal positions.
- **No filter / search / focus mode.** Deliberately deferred. The page renders
  the full board; if it grows past ~30 cards the operator can scroll.
- **No multi-project support.** Spec assumes one active orchestrator install at
  a time. Multi-project is a future feature.
- **No browser-side authentication.** Same loopback-only binding as today's
  dashboard. If you need remote access, SSH-tunnel.

## User journey

1. Operator runs `./.claude/scripts/dashboard.sh start` (existing command;
   unchanged).
2. Opens `http://127.0.0.1:5174/` and sees the existing 6-panel view (default,
   unchanged).
3. Clicks a new "Board" link in the top nav. Browser navigates to `/board`.
4. Sees seven columns left-to-right with current tasks distributed across
   them. Each in-progress card carries a named agent ("Cmdr. Lovelace") with
   an avatar; done cards carry a cost badge ("$0.42"); blocked cards carry a
   small joke about needing a human.
5. Clicks any card → opens the linked GitHub PR (or issue, if no PR yet) in a
   new tab.
6. Leaves the tab open. The board polls `/api/board` every 5 seconds and
   re-renders. Card position changes as the orchestrator advances state.

## Architecture

```
Browser (board.html + board.js + board.css)
        │ poll every 5 s
        ▼
Flask /api/board   ──>   join into {columns: {todo: [card,...], ...}}
        │
        ├─ reads .claude/plans/*.state.json (active + archived)
        ├─ reads .claude/state/events.jsonl (for cost rollup + recency)
        ├─ reads .claude/state/active_worktrees.txt (worker→task)
        ├─ gh issue/PR list (reuse existing 30 s cache in api_github.py)
        └─ static lookups: agents.json (name pool), blocked_jokes.json
```

The view is purely a composition over data sources that already exist (or
were just added by PR #43). No new persistent state on disk — the dashboard's
existing `dashboard.pid` / `dashboard.log` / `dashboard-venv/` cover all
process state. The agent name pool and joke pool ship as static JSON inside
`dashboard/static/`.

## Component breakdown

| Component | Purpose | Depends on |
|-----------|---------|------------|
| `dashboard/api_board.py` | New endpoint at `GET /api/board`. Reads all data sources, composes the columns dict, returns JSON. | `api_plan`, `api_workers`, `api_github`, `_dispatcher_lib.sh`-compatible state parser |
| `dashboard/api_costs.py` | New helper: given a task, sums `usage.total_tokens × model_rate` across all `run-N-r*.json` and `review-N.json` files. Cached in-memory keyed by `(plan, task, mtime)`. | reads `.claude/state/*.json`, hardcoded price table |
| `dashboard/templates/board.html` | New template. Top nav with Home / Board, 7-column grid below. | `static/board.css`, `static/board.js` |
| `dashboard/static/board.js` | Polls `/api/board` every 5 s, renders cards, attaches click handlers. | DOM only; no React/Vue. Plain JS to match the existing codebase. |
| `dashboard/static/board.css` | Column grid, card styling, avatar circle, badge styling. Theming consistent with existing panels. | — |
| `dashboard/static/agents.json` | Curated pool of ~20 character names + DiceBear seed strings. One entry marked `role: reviewer` (always Argus). | — |
| `dashboard/static/blocked_jokes.json` | ~20 one-liner strings for the Blocked column. | — |
| `dashboard/app.py` | One added route `@app.route("/board")` returning `board.html`. One added blueprint registration for `api_board`. | existing |

Each unit has one purpose, communicates through a defined interface
(JSON over HTTP for the API surfaces, function arguments for the helpers),
and can be understood without reading the others.

## Column mapping

Source of truth: composition function inside `api_board.py`. Pure function
of `(active_state_files, archived_state_files, gh_issues, gh_prs,
active_worktrees)`. Unit-testable in isolation.

| Column | Source rule |
|--------|-------------|
| **Backlog** | Open GH issues with label `monitor:finding` (one card per issue). Plus plans archived with `status: blocked` due to unmet `requires:` — **one card per archived plan**, not per task. Card title is the plan slug; `click_url` opens the plan file on GitHub. |
| **Todo** | Tasks with `status: pending` across all active plans. |
| **In Progress** | Tasks with `status: in_progress`. The active worktree manifest provides the worker PID for display. |
| **Ready For Review** | Tasks with `status: in_review` whose PR is open AND has no review verdict on the current HEAD SHA (no `orch:review-sha:<HEAD>` label). |
| **In Review** | Tasks with `status: in_review` whose PR is open AND has `orch:review-sha:<HEAD>` AND either `orch:review-blocked` label OR a running iterator (matched via `ps` like the workers panel does today). Badge shows `iterating r<N>/5` when applicable. |
| **Blocked** | Tasks with `status: blocked` PLUS in-review tasks where `auto_merge_overrides[N] == false` and the PR carries `orch:needs-robbie`. Sensitive flag rendered as a small shield icon. |
| **Done** | Tasks with `status: merged`. Cost badge shown (see Cost rollup). |

A task can appear in **exactly one** column. The order above is the
precedence: if a row could match multiple rules, the leftmost-listed column
wins. (In practice the rules are disjoint by FSM status, except for the
sensitive-in-review case which Blocked claims over Ready/In Review.)

## Card schema

The columns-builder emits one `card` object per cell. Schema:

```jsonc
{
  "plan": "PLAN-05",                 // plan slug (for label)
  "task": 3,                          // task number
  "title": "Add receipt-sender Lambda",
  "depends_on": [1, 2],
  "issue": 41,                        // GH issue # (nullable until refresh-deps)
  "pr": 142,                          // GH PR # (nullable until launch-worker pushes)
  "click_url": "https://github.com/…/pull/142",  // PR if exists, else issue, else null
  "status": "in_progress",            // raw FSM status (for tooltip / debugging)
  "sensitive": false,                 // auto_merge_overrides[N] == false
  "agent": {
    "name": "Cmdr. Lovelace",
    "avatar_seed": "lovelace",        // DiceBear seed; client builds the URL
    "role": "worker"                  // see role mapping table below
  },
  "badges": [                         // 0..N small strings rendered as pills
    "iterating r2/5"
  ],
  "cost_usd": 0.42,                   // present only on Done cards; null if pre-feature
  "joke": "404: human-in-the-loop not found.",   // present only on Blocked cards
  "blocked_reason": "review_iter_cap" // present only on Blocked cards
}
```

The frontend treats every field as optional and renders defensively. New
fields can be added server-side without breaking older browsers (operators
do refresh).

## Card rendering (one card, default state)

```
┌─────────────────────────────────────────────┐
│ PLAN-05 · T3                       🛡 sens │
│ ─────────────────────────────────────────── │
│ Add receipt-sender Lambda                   │
│                                             │
│ 🧑 Cmdr. Lovelace          deps: T1, T2     │
│                                             │
│ #142    iterating r2/5     $0.42            │
└─────────────────────────────────────────────┘
```

Click anywhere on the card surface opens `click_url` in a new tab. Hover
shows a tooltip with the raw FSM status (helpful for "why is this in
Blocked?" introspection).

## Agent identity system

Agent `role` per column (which character renders on the card):

| Column | `role` | Character shown |
|--------|--------|-----------------|
| Backlog | `null` | None (issue/plan icon instead) |
| Todo | `null` | None (deps shown instead) |
| In Progress | `worker` | Per-task character from pool |
| Ready For Review | `worker` | Same per-task character (the worker who just finished) |
| In Review (review-blocked, awaiting iteration) | `reviewer` | Argus (fixed) |
| In Review (iterating) | `iterator` | Same per-task character (iterator inherits the worker's identity since it's the same plan+task) |
| Blocked | `worker` | Per-task character with the joke pill |
| Done | `null` | None |

Three character classes feed those slots:

1. **Workers / iterators** — diverse curated pool of exactly 20 computing-themed
   characters. Mix across geography, era, and gender; explicit goal is
   >50% non-white-male representation. Starting roster (revisable during
   implementation; final list owned by the implementation plan):
   Hopper, Lovelace, al-Khwarizmi, Aryabhata, Liskov, Sutherland, Goldstine,
   Diffie, Hellman, Berners-Lee, Lamarr, Kahn, Wozniak, Knuth, Tarjan,
   Marvin, KITT, Bender, R2D2, WALL·E.

   Mapping: `agent_index = hash(plan_slug + ":" + task_num) % pool_size`.
   Deterministic — task 3 of PLAN-05 is always the same character across
   retries, iterations, and dashboard restarts. Operator builds memory.

2. **Reviewer** — single fixed character, always **Argus** (the many-eyed
   watcher from Greek myth — apt for a code reviewer). One distinct avatar.
   Rendered on every In Review card whose review job is active.

3. **Avatars** — DiceBear v8 SVGs, served from `https://api.dicebear.com/8.x/<style>/svg?seed=<seed>`.
   Style choice (`thumbs` / `bottts` / `lorelei`) decided in implementation
   plan based on visual coherence. Fallback to a generated initials-on-color
   SVG if DiceBear is unreachable (dashboard is loopback-only but the
   browser still needs internet to load the SVG; absent network falls back).

## Blocked-card jokes

`dashboard/static/blocked_jokes.json` — array of ~20 one-liners. Tone:
self-deprecating about the agent ("I tried. Brain too small. Send human."),
or affectionate about humans ("404: human-in-the-loop not found.").
Rotates by `hash(plan_slug + ":" + task_num + ":" + utc_date) % pool_size`
so the same blocked task shows the same joke for the same UTC day but
something different tomorrow — keeps the page from feeling stale without
flickering on every poll.

## Cost rollup

Per-task cost = sum of token-usage cost across all worker, iterator, and
reviewer runs for that task.

- **Data sources:** `.claude/state/run-<task>-r<retry>.json`,
  `.claude/state/review-<task>-r<retry>.json` (the `claude -p
  --output-format json` outputs that `_dispatcher_lib.sh:extract_usage_summary`
  already parses).
- **Pricing table:** hardcoded in `api_costs.py`. Schema:
  `{model_id: {input_per_mtok, output_per_mtok, cache_read_per_mtok, cache_write_per_mtok}}`.
  Sourced from `https://www.anthropic.com/pricing` at implementation time;
  versioned in-file with a comment naming the snapshot date.
- **Cache:** in-memory dict keyed by `(plan, task, last_run_mtime)`. Invalidated
  automatically when a new run file appears (mtime change). No disk cache.
- **Display:** USD, two decimals (`$0.42`). Renders only on Done cards. Tasks
  merged before this feature ships have no `run-*.json` files for partial
  retries, but the final run is preserved; if no run files exist at all
  (very old tasks), show "—" instead of "$0".
- **Future-proofing:** the `task_merged` event in events.jsonl gains an
  optional `cost_usd` extra so a future dashboard can read the cost without
  walking the run files. Out of scope for v1 to write that — implementation
  plan tracks it as a small subsequent task.

## Plan-status labels

Each card carries a small `PLAN-05` pill in its top-left. When multiple
active plans are running, cards mix in the columns and the pill is the
disambiguator. Color is derived from `hash(plan_slug) % 8` against a fixed
palette so the same plan always renders the same color.

## API surface

### `GET /api/board`

Response (snipped):

```json
{
  "as_of": "2026-05-26T10:00:00Z",
  "columns": {
    "backlog":          [card, ...],
    "todo":             [card, ...],
    "in_progress":      [card, ...],
    "ready_for_review": [card, ...],
    "in_review":        [card, ...],
    "blocked":          [card, ...],
    "done":             [card, ...]
  },
  "errors": []
}
```

`errors` is non-empty when a partial data source failed (e.g. `gh` timed
out, state file unreadable). Each entry: `{source, message, suggestion}`,
same shape the existing panels already use for their error UI. The board
renders whatever columns it could build; affected columns get a small
banner.

## File layout

```
orchestrator-kit/.claude/scripts/dashboard/
├── app.py                          # +1 route, +1 blueprint registration
├── api_board.py                    # NEW
├── api_costs.py                    # NEW
├── api_plan.py                     # unchanged
├── api_workers.py                  # unchanged
├── api_github.py                   # unchanged (reused for monitor:finding lookup)
├── templates/
│   ├── index.html                  # unchanged (gets a nav link to /board)
│   └── board.html                  # NEW
└── static/
    ├── (existing assets)           # unchanged
    ├── board.js                    # NEW
    ├── board.css                   # NEW
    ├── agents.json                 # NEW
    └── blocked_jokes.json          # NEW

orchestrator-kit/tests/
└── _test_board_api.sh              # NEW
```

Also updates:

- `orchestrator-kit/docs/DASHBOARD.md` — adds a "Board view" section with
  the column mapping table and a screenshot.
- `orchestrator-kit/README.md` — one-line mention of the board under the
  "Local dashboard" pointer.
- Drift CI passes automatically because all new files live under
  `.claude/scripts/dashboard/` which is in the kit-owned manifest.

## Testing

`_test_board_api.sh` exercises the column-builder pure function with
synthetic inputs:

| Scenario | Asserts |
|----------|---------|
| Empty inputs | All 7 columns are empty arrays; `errors` is empty. |
| One task per FSM status | Each task lands in the expected column. |
| Sensitive in-review with `orch:needs-robbie` | Lands in Blocked, not In Review. |
| Iterator running on review-blocked PR | Lands in In Review with `iterating rN/5` badge. |
| Monitor finding issue | Lands in Backlog with `click_url` pointing to the issue. |
| Done card with run files | `cost_usd` is a positive number. |
| Done card without run files | `cost_usd` is null; UI shows "—" (verified by separate JS sanity check, not in this test). |
| Two tasks across two plans | Both render with their respective plan pills. |
| Partial GH outage | Affected column has an `errors` entry; other columns still render. |

No browser test in v1. The static rendering layer is small enough to
eyeball during development.

## Risks

| Risk | Mitigation |
|------|------------|
| DiceBear network dependency in an otherwise-loopback tool | Fallback to initials-on-color SVG generated client-side from the seed. Documented. |
| Cost pricing table drifts when Anthropic changes prices | Versioned in-file with a snapshot date. Drift is correctly-bounded (old tasks render with old prices is fine for "what did this cost"; new tasks need new prices). README notes how to refresh. |
| Column mapping logic accumulates edge cases as the FSM evolves | All logic in one pure function with the test matrix above; new edge cases get new scenarios. |
| Operator confusion if a task is in an unexpected column | Tooltip on hover surfaces the raw FSM status + rule that placed it there. |

## Out of scope for v1 (tracked for future)

- Filter / search / focus mode
- Drag-and-drop or quick-action buttons
- Multi-project view
- Real-time updates via SSE / WebSocket (5 s polling is fine)
- Mobile / touch layout (desktop-only)
- Theme switching (light/dark)
- Cost-budget alerts (a card lights up when its cost exceeds a threshold)
- Aggregate views (cost per plan, agent leaderboard, mean-time-to-merge)

## Open questions resolved

| Question | Decision |
|----------|----------|
| New view vs replace existing | New tab "Board" on existing dashboard (Approach A) |
| Ready For Review vs In Review split | By review stage (PR pushed, no review verdict on current SHA) |
| Iterator-working location | In Review column with `iterating rN/5` badge |
| Backlog scope | Monitor findings + plans archived as blocked-on-upstream |
| Agent identity | Deterministic per task; curated diverse pool; fixed reviewer ("Argus"); jokes on blocked cards |
| Interactivity | Read-only mirror + click-through only |
