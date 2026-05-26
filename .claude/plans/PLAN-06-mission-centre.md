# PLAN-06-mission-centre — unified kanban + telemetry dashboard view

Build the Mission Centre: a single-page Flask dashboard view that combines a
seven-column kanban board over the active plan(s), an Active Workers detail
panel with named bot agents, plan progress, live orchestrator log tail,
structured event activity stream, GitHub issues+PRs, and a cost rollup. Full
design lives in `orchestrator-kit/docs/SPEC-mission-centre.md`; visual
reference is the static mockup at
`orchestrator-kit/docs/mockups/mission-centre-unified.html`.

The view is a read-only mirror of orchestrator state — state changes happen
via the orchestrator itself (cron / routine / `/loop`) and the page re-renders
on a 5-second poll. Cards click through to GitHub. The existing 6-panel
dashboard remains accessible at `/dashboard` for operators who prefer it.

**Kit-drift discipline:** every task that touches a kit-owned file under
`.claude/scripts/dashboard/` MUST keep the root install in sync. The
recommended flow is: edit the canonical copy under
`orchestrator-kit/.claude/scripts/dashboard/`, then run
`bash orchestrator-kit/.claude/scripts/kit-upgrade.sh orchestrator-kit --apply`
before committing. The `kit-drift` CI job (added in PR #43) fails otherwise.
Tests at `orchestrator-kit/tests/` and project docs at `orchestrator-kit/docs/`
are kit-source-only and not subject to drift.

## Task 1: Add static asset files (agents pool + blocked-card jokes)
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/static/agents.json`, `orchestrator-kit/.claude/scripts/dashboard/static/blocked_jokes.json`, `.claude/scripts/dashboard/static/agents.json`, `.claude/scripts/dashboard/static/blocked_jokes.json`]
**acceptance:** [`agents.json contains exactly 21 entries: 20 workers (Pip, Bento, Nova, Echo, Glitch, Bug, Mochi, Cosmo, Pixel, Spark, Tofu, Otter, Pepper, Patch, Loop, Snap, Tweak, Zog, Boop, Comet) plus one reviewer named Argus`, `each entry has name, seed, and role fields where role is worker or reviewer`, `blocked_jokes.json contains at least 15 distinct one-liner strings`, `both files validate as JSON via python -m json.tool`, `kit-drift CI passes (root install in sync)`]

Create `agents.json` as an array of objects with shape
`{name, seed, role}`. The 20 worker entries use `role: worker` with the names
listed above; the single reviewer entry uses `role: reviewer` and `name: Argus`.
Seed equals name for simplicity (DiceBear hashes the seed).

Create `blocked_jokes.json` as a flat array of short, self-deprecating-about-
the-agent or affectionate-about-humans strings (e.g. "I tried. Brain too
small. Send human.", "404: human-in-the-loop not found."). Avoid embedded
backticks or double-quotes inside the joke strings.

Sync root install via kit-upgrade.sh --apply. Commit: `feat(dashboard): add agent name pool + blocked-card joke pool`.

## Task 2: Add cost-rollup module (api_costs.py)
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/api_costs.py`, `.claude/scripts/dashboard/api_costs.py`]
**acceptance:** [`api_costs.py exports cost_for_task(plan, task) returning a USD float summing usage across all matching run-N-rR.json files`, `api_costs.py exports cost_today() returning a dict with today_usd, by_role, yesterday_usd, this_week_usd keys`, `pricing table is hardcoded in-file with a snapshot date comment naming the source URL`, `in-memory cache is keyed by plan, task, retry, mtime and invalidates on file mtime change`, `module returns 0.0 or empty dict gracefully when run files are absent (no exceptions raised)`, `kit-drift CI passes`]

Per-task cost is the sum of `usage.total_tokens × per-model-rate` over
`.claude/state/run-<task>-r<retry>.json` and
`.claude/state/review-<task>-r<retry>.json` files. Pricing table is a
hardcoded dict at the top of the file keyed by model id with sub-keys
`{input_per_mtok, output_per_mtok, cache_read_per_mtok, cache_write_per_mtok}`.
Source from https://www.anthropic.com/pricing at implementation time and
comment the snapshot date. Cache keyed by `(plan, task, retry, mtime)` for
fast repeat lookups; invalidate when mtime advances.

Sync root install via kit-upgrade.sh --apply. Commit: `feat(dashboard): add api_costs.py token-to-USD rollup with mtime cache`.

## Task 3: Extend api_workers.py with last_log line per worker
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/api_workers.py`, `.claude/scripts/dashboard/api_workers.py`]
**acceptance:** [`/api/workers response objects include a last_log field`, `last_log is the most recent meaningful line from the workers run-N-rR.json (assistant text, tool use summary, or result)`, `last_log is null or omitted gracefully when the run file is missing or unparseable (best-effort)`, `existing /api/workers fields are unchanged (backward compatible)`, `kit-drift CI passes`]

Tail each active worker's run JSON file (the newest matching
`run-<task>-r*.json` by mtime), parse the most recent message that carries
useful text (assistant output, tool name + argument snippet, or final
result), and surface it as a one-line string for the Active Workers panel.
Best-effort throughout: if no file or parse fails, omit or null the field
rather than fail the panel.

Sync root install via kit-upgrade.sh --apply. Commit: `feat(dashboard): surface last log line per worker in /api/workers`.

## Task 4: Add unified /api/board composer (api_board.py)
**depends_on:** [1, 2, 3]
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/api_board.py`, `.claude/scripts/dashboard/api_board.py`]
**acceptance:** [`GET /api/board returns the schema documented in SPEC-mission-centre.md API surface section (board, workers, plan_status, cost, log_tail, activity, github, errors)`, `seven columns are computed by a pure function of state files, archived states, gh issues, gh prs, worktrees, and pr reviews`, `agent assignment is deterministic: same (plan, task) returns the same agent name across calls`, `Argus is always returned for the reviewer role regardless of task`, `sensitive-flagged in-review tasks land in Blocked (not In Review)`, `partial source failures populate the errors array without crashing other panels`, `endpoint is registered as a Flask blueprint and reachable via /api/board`, `kit-drift CI passes`]

Compose the unified payload by reading active and archived state files, GH
issues and PRs via the existing api_github.py 30s cache, the active worktree
manifest, and PR reviews. Use api_costs.py for cost rollup; agents.json for
the name pool. The column-builder is a pure function over its inputs
(testable in isolation per T7). Error handling: each source's failure goes
into the errors array with `{source, message, suggestion}`; affected panels render a
data-unavailable banner client-side but the rest of the response still works.

Sync root install via kit-upgrade.sh --apply. Commit: `feat(dashboard): add /api/board unified payload composer`.

## Task 5: Add Mission Centre frontend (template + CSS + JS)
**depends_on:** [4]
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/templates/board.html`, `orchestrator-kit/.claude/scripts/dashboard/static/board.css`, `orchestrator-kit/.claude/scripts/dashboard/static/board.js`, `.claude/scripts/dashboard/templates/board.html`, `.claude/scripts/dashboard/static/board.css`, `.claude/scripts/dashboard/static/board.js`]
**acceptance:** [`board.html renders the unified Mission Centre layout: top nav, optional alerts strip, board (7 columns), right rail (Active Workers + Plan Status + Cost), live log, recent activity, GitHub panel`, `board.js polls /api/board every 5 seconds and re-renders without losing scroll position`, `clicking any card opens its click_url in a new tab`, `only the Todo column has internal scroll; other columns stay compact`, `agent avatars load from DiceBear bottts; fall back to client-side initials-on-color SVG if DiceBear is unreachable`, `Blocked cards show the joke pulled from blocked_jokes.json rotated by plan, task, and utc_date`, `Done cards show the cost badge`, `layout fills the viewport (no max-width centering)`, `visual parity with orchestrator-kit/docs/mockups/mission-centre-unified.html`, `kit-drift CI passes`]

Render the full Mission Centre per the mockup
(`orchestrator-kit/docs/mockups/mission-centre-unified.html`) and the layout
described in SPEC Page-layout section. Use plain JS — no framework, matching
the existing dashboard codebase. DiceBear URL pattern:
`https://api.dicebear.com/8.x/bottts/svg?seed=<name>&backgroundType=gradientLinear`.
Argus uses `backgroundColor=db61a2`. Fallback SVG when DiceBear is
unreachable: generate client-side from name initial plus a color picked by
hash(name) modulo a small palette. Polling preserves scroll position by
capturing scrollTop on each panel before re-render and restoring it after.

Sync root install via kit-upgrade.sh --apply. Commit: `feat(dashboard): add Mission Centre frontend (board.html, board.css, board.js)`.

## Task 6: Swap default route to Mission Centre (app.py)
**depends_on:** [4, 5]
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/app.py`, `.claude/scripts/dashboard/app.py`]
**acceptance:** [`GET / returns board.html (Mission Centre is the new default landing page)`, `GET /dashboard returns the legacy 6-panel index.html`, `api_board and api_costs blueprints are registered alongside the existing blueprints`, `every existing /api/* endpoint still responds with unchanged shape`, `dashboard.sh start, stop, status, and restart subcommands all still work`, `kit-drift CI passes`]

Add `@app.route("/")` for board.html and move the existing legacy view to
`@app.route("/dashboard")`. Register the new blueprints (api_board, api_costs)
alongside the existing ones. Do not change any existing route or blueprint
beyond the / → /dashboard relocation. Verify with curl that all six existing
/api/* endpoints still respond as before.

Sync root install via kit-upgrade.sh --apply. Commit: `feat(dashboard): serve Mission Centre at /, legacy panels at /dashboard`.

## Task 7: Add _test_board_api.sh covering column-builder + cost-rollup
**depends_on:** [2, 4]
**touches:** [`orchestrator-kit/tests/_test_board_api.sh`]
**acceptance:** [`test file is executable and runs via bash orchestrator-kit/tests/_test_board_api.sh`, `tests cover all 11 scenarios listed in SPEC Testing section`, `every assertion uses the pass and fail helper pattern shared with other _test_*.sh files`, `script exits 0 on all-pass, 1 on any failure`, `runs offline with no gh, no network, no claude calls`]

Implement the test matrix from SPEC Testing section. Use mktemp tmpdirs plus
synthetic state files, mock the data sources by stubbing in-memory dicts
where api_board.py reads them. Follow the convention of _test_aws_env.sh and
_test_plan_promote.sh (pass/fail helpers, tmpdir cleanup via trap). Tests
live only in `orchestrator-kit/tests/` — not mirrored to the root install,
since tests are not part of the kit-drift manifest.

Commit: `test(dashboard): add column-builder + cost-rollup regression tests`.

## Task 8: Update docs (DASHBOARD.md + README.md)
**depends_on:** [6]
**touches:** [`orchestrator-kit/docs/DASHBOARD.md`, `orchestrator-kit/README.md`]
**acceptance:** [`DASHBOARD.md has a new Mission Centre section describing the unified layout, column mapping, agent identity, and how to reach the legacy view at /dashboard`, `README.md Local dashboard pointer mentions Mission Centre is the default landing page`, `at least one reference to the mockup file orchestrator-kit/docs/mockups/mission-centre-unified.html for visual context`, `no broken intra-repo links in either file`]

Add a Mission Centre section to DASHBOARD.md with the column mapping table,
the agent identity scheme, the cost panel description, and the / vs
/dashboard URL split. Update README.md's existing dashboard mention to note
Mission Centre is the new default. Reference the mockup file for visual
context. Do not move or rewrite existing content unrelated to this feature.

Commit: `docs(dashboard): document Mission Centre layout and routing`.
