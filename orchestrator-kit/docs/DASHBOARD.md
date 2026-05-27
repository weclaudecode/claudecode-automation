# Local dashboard

A localhost-only Flask web dashboard that surfaces the orchestrator's live
state to the operator. Read-only, no auth, single-operator local tool —
not a production-grade monitoring stack.

## Quick start

From the repo root where the kit is installed:

```bash
./.claude/scripts/dashboard.sh start
```

Then open `http://127.0.0.1:5174/` in a browser. The landing page is the
**[Mission Centre](#mission-centre)** — a unified seven-column kanban
board with telemetry rails around it. The previous six-panel layout
(Alerts strip, Plan Status, Logs, Issues + PRs, Workers, Config) is
still available at `http://127.0.0.1:5174/dashboard` for operators who
prefer it; that view is documented under
[Legacy view panels (`/dashboard`)](#legacy-view-panels-dashboard) below.

Sources at a glance (both views read the same underlying state):

| Surface       | Source                                                  |
|---------------|---------------------------------------------------------|
| Board columns | `api_board.py` over active + archived state files, GH issues, PRs, active worktrees |
| Alerts strip  | union of blocked-task / needs-robbie / monitor / dead-orchestrator |
| Plan Status   | active `.claude/plans/*.state.json`                     |
| Logs          | `.claude/state/orchestrator.log` (tail)                 |
| Issues + PRs  | `gh issue list` + `gh pr list` (30s cache, with CI dot) |
| Workers       | `ps` for `claude -p` + active-worktrees manifest        |
| Cost          | `run-*.json` × pricing snapshot in `api_costs.py`       |
| Config        | env vars + `.claude/settings.json` + plan state         |

To stop:

```bash
./.claude/scripts/dashboard.sh stop
```

Other subcommands: `status`, `restart`, `--help`.

## Mission Centre

The default landing page at `http://127.0.0.1:5174/` is the **Mission
Centre** — a unified seven-column kanban board across the top with
telemetry rails (workers, plan status, cost, live log, recent activity,
GitHub) tucked around it. One page, no tab switching: it answers "what
is the orchestrator doing right now and what does it need from me?".

The legacy six-panel view (Alerts strip, Plan Status, Logs, Issues +
PRs, Workers, Config) lives at `http://127.0.0.1:5174/dashboard`.
Everything described in
[Legacy view panels (`/dashboard`)](#legacy-view-panels-dashboard) below
applies to that route.

Visual reference: open
[`mockups/mission-centre-unified.html`](mockups/mission-centre-unified.html)
in a browser for the approved target layout, colors, and card density.
The board is hot-reloaded by polling `/api/board` every 5 s, so the
template at `templates/board.html` is intentionally Jinja-free —
`api_board.py` is the only source of state.

### Column mapping

Each task appears in exactly one of seven columns. The pure-function
column builder lives in `api_board.py::build_board`; the full test
matrix is in `orchestrator-kit/tests/_test_board_api.sh`.

| Column | Source rule |
|--------|-------------|
| **Backlog** | Open GH issues labelled `monitor:finding`; plus plans archived with `status: blocked` from unmet `requires:`. |
| **Todo** | Tasks with `status: pending`. Only column that scrolls (max-height ~360 px). |
| **In Progress** | Tasks with `status: in_progress`. Worker PID comes from the active-worktree manifest. |
| **Ready For Review** | `status: in_review`, PR open, no `orch:review-sha:<HEAD>` label yet. |
| **In Review** | `status: in_review`, PR open, has `orch:review-sha:<HEAD>` AND (`orch:review-blocked` label OR running iterator). |
| **Blocked** | `status: blocked` PLUS in-review tasks where `auto_merge_overrides[N] == false` and the PR carries `orch:needs-robbie` (sensitive flag). |
| **Done** | `status: merged`. |

Precedence is top-down: a sensitive in-review task lands in **Blocked**,
not In Review. Note also that the `merged → Done` rule is applied
**before** any `orch:safety-block` label check, so a PR that is
already on `main` never flashes through Blocked during the gap between
`gh pr merge` and the next `sweep-merges` tick.

### Agent identity

Each card carries an avatar so the operator builds per-task memory
across retries and dashboard restarts.

- **Workers / iterators** — pool of 20 one-word names (Pip, Bento,
  Nova, Echo, Glitch, Bug, Mochi, Cosmo, Pixel, Spark, Tofu, Otter,
  Pepper, Patch, Loop, Snap, Tweak, Zog, Boop, Comet) defined in
  `static/agents.json`. Mapping: `agent_index = md5(plan_slug + ":" +
  task_num) % 20`. Deterministic — task 3 of PLAN-05 is always the
  same character. Python's built-in `hash()` is intentionally not used:
  it is `PYTHONHASHSEED`-randomized and would silently reshuffle every
  avatar on every dashboard restart.
- **Reviewer** — fixed character **Argus** with a pink DiceBear
  background, pinned to every In Review card awaiting reviewer verdict.
  When an iterator picks up after `orch:review-blocked`, the card swaps
  back to the worker's per-task character (the iterator inherits the
  worker's identity for continuity).
- **Avatars** — DiceBear v8 `bottts` style, fetched from
  `https://api.dicebear.com`. The frontend checks `naturalWidth === 0`
  in the image `onload` handler to detect a CDN error page served with
  HTTP 200 (where `onerror` doesn't fire). When DiceBear is unreachable,
  the fallback is a client-side initials-on-color SVG generated from
  the agent name — no network required for the offline case.

The per-column role mapping (which character class appears where) is
documented in
[`SPEC-mission-centre.md`](SPEC-mission-centre.md) § "Agent role per
column".

### Cost panel

Headline is **tokens consumed today** (input + output, summed across
all worker, reviewer, and iterator run files) — the real meter for an
operator on a Max subscription. The dollar figure is shown as a
secondary "API-equivalent" line so it stays comparable to a
pay-per-call deployment but isn't the primary signal. The pricing
snapshot lives inline in `api_costs.py` with a snapshot-date comment
naming the source URL; bump it when Anthropic publishes new rates.

### Blocked-card jokes

Blocked cards show a one-line joke from `static/blocked_jokes.json`.
Rotation key: `md5(plan_slug + ":" + task_num + ":" + utc_date) %
len(jokes)` — same blocked task shows the same joke today and a
different one tomorrow, so the page stays animated without churning on
every 5 s poll. `utc_date` is a required argument to `build_board`
(not derived from `datetime.now()` inside the builder) so the joke can
never flip mid-poll at 00:00 UTC.

### Files added for Mission Centre

```
.claude/scripts/dashboard/
  api_board.py            — pure-function column builder + payload composer
  api_costs.py            — token + USD rollup
  api_workers.py          — extended with last_log line per worker
  templates/
    board.html            — Mission Centre landing template (no Jinja substitutions)
  static/
    board.css             — Mission Centre styles
    board.js              — Mission Centre frontend, polls /api/board every 5 s
    agents.json           — 20 workers + Argus
    blocked_jokes.json    — joke pool
```

## Legacy view panels (`/dashboard`)

Everything in this section describes the six-panel view served at
`http://127.0.0.1:5174/dashboard`. It is unchanged from prior versions
and remains the canonical reference for the underlying endpoints —
`/api/alerts`, `/api/plan`, `/api/logs`, `/api/github`, `/api/workers`,
and `/api/config`. The [Mission Centre](#mission-centre) at `/` is a
superset built from the same data plus `/api/board`.

**Alerts strip** — sits between the header and the panel grid. Hidden
when empty. Surfaces four alert kinds that would otherwise be buried
in the regular panels:

| Kind                 | Source                                         | Severity                                    |
|----------------------|------------------------------------------------|---------------------------------------------|
| `blocked`            | tasks with `status: blocked` in active state   | `error`                                     |
| `needs_robbie`       | open PRs labelled `orch:needs-robbie`          | `warn`                                      |
| `monitor`            | open issues labelled `monitor:finding`         | `warn` if H1/H2/H4 in title, else `info`    |
| `dead_orchestrator`  | no `=== tick ===` line for > 2× expected interval | `error`                                  |

Each card shows a severity glyph (❗/⚠/ⓘ), one-line summary, "since"
relative time, optional open-link, and a ❓ button that pops the
suggested action with a copy-to-clipboard option. The strip
auto-expands when any alert is `error`-severity; otherwise it renders
collapsed with a count summary.

**Plan Status** — current active plan (newest `in_progress` state file),
total tasks, plus a per-task table with status, dependencies, touches,
issue/PR numbers, retries, and (where applicable) `blocked_reason` or
`merged_at`. Task rows are colour-coded by status (pending=gray,
in_progress=blue, in_review=yellow, merged=green, blocked=red). Blocked
tasks get a ❓ icon next to `blocked_reason` that pops the matching
runbook entry (see [Runbook hints](#runbook-hints)).

**Logs** — last 200 lines of `orchestrator.log`. Tick boundaries
(`=== tick <iso> ===`) and phase boundaries (`--- phase N ---`) are
highlighted. Lines with `warning:` and `error:` get colour-coded
levels. The panel auto-scrolls to the latest line unless the operator
scrolls up — scrolling back to the bottom re-engages auto-scroll.

**Issues + PRs** — open GitHub issues (most recent 50) and recent PRs
(most recent 30, both merged and open). Backed by `gh` CLI with a 30s
in-memory cache so the 5s frontend poll doesn't hammer the GitHub API.
Each PR row is prefixed by a CI status dot derived from
`statusCheckRollup`:

| `ci_state` | Glyph | Meaning                                                       |
|------------|-------|---------------------------------------------------------------|
| `SUCCESS`  | ● green | All checks passed                                           |
| `FAILURE`  | ● red   | At least one check is failure/error/cancelled/timed-out     |
| `PENDING`  | ◐ yellow | At least one check is pending or in-progress (no failures) |
| `null`     | — gray | No CI checks configured for this PR                          |

**Workers** — active `claude -p` processes (matched via `ps`) and active
worktrees from `.claude/state/active_worktrees.txt` (filtered to entries
whose path still exists). Worker PIDs are linked to their worktree by
path. Command lines are sanitised before display: env-var prefixes that
look secret-bearing (containing `TOKEN`, `SECRET`, `KEY`, `AWS_`,
`GITHUB_`, `ANTHROPIC_`, `PASSWORD`, `AUTH`, `CREDENTIAL`) are
over-redacted to `<redacted>`.

**Config** — current effective values of the tunables below, plus each
value's source (env var, default, `.claude/settings.json`, or per-plan
state). See [Tunables](#tunables) for the canonical list.

**Header strip** — active plan slug + tick counter (derived from log
parse) + global pause-polling toggle + `?` button that opens the
in-app help overlay.

## Runbook hints

Several places in the UI render a small ❓ help icon: blocked task
rows, panel fetch errors, and soft envelope warnings. Clicking pops a
short remediation snippet pulled from `static/runbook.js`.

Current runbook keys:

| Key                          | When it fires                                                 |
|------------------------------|---------------------------------------------------------------|
| `worker_failed_3x`           | task block from 3× worker failure                             |
| `iterate_failed_3x`          | task block from 3× iterator failure                           |
| `review_iter_cap`            | task block from review loop hitting `ORCH_MAX_TURNS`          |
| `pr_closed_unmerged`         | task block because PR closed without merging                  |
| `upstream_blocked_t<N>`      | cascade block (matched via prefix, any N)                     |
| `gh CLI not found`           | panel fetch error from missing `gh` binary                    |
| `gh timed out`               | panel fetch error from `gh` subprocess timeout                |
| `ps timed out`               | workers panel timed out reading the process table             |
| `state file unreadable`      | plan panel can't parse the active `*.state.json`              |
| `fetch failed`               | browser couldn't reach the Flask backend                      |

Add a key by appending an entry in `runbook.js` and (optionally)
extending the table above. The popover supports up to ~8 lines per
entry comfortably.

## Keyboard shortcuts

| Key   | Action                                   |
|-------|------------------------------------------|
| `r`   | refresh all panels                       |
| `p`   | toggle polling (pause / resume)          |
| `?`   | open / close the help overlay            |
| `Esc` | close any open popover or the help overlay |

The same keys are listed inside the help overlay so first-time
operators don't need to find them in this file.

## Tunables

These are the knobs the dashboard surfaces. Adding new tunables means
updating `TUNABLES` in `.claude/scripts/dashboard/api_config.py` (a
manual sync — there is no CI check for drift between code and these
docs).

| Env var                  | Default     | Description                                                |
|--------------------------|-------------|------------------------------------------------------------|
| `ORCH_MAX_PARALLEL`      | `1`         | Max parallel workers per tick                              |
| `ORCH_WORKER_MODEL`      | `opus`      | Worker/iterator model (`sonnet` \| `opus` \| `haiku`)      |
| `ORCH_REVIEWER_MODEL`    | `opus`      | Reviewer coordinator model (`sonnet` \| `opus` \| `haiku`) |
| `ORCH_MAX_TURNS`         | `30`        | `claude -p --max-turns` cap                                |
| `ORCH_AUTO_RECOMMENDED`  | `0`         | Default auto-resolve for ambiguous decisions               |
| `ORCH_LOG_MAX_BYTES`     | `10485760`  | Log rotation threshold (bytes — default 10 MiB)            |
| `ORCH_DASHBOARD_PORT`    | `5174`      | Port the dashboard listens on (`127.0.0.1` only)           |
| `ORCH_DASHBOARD_EXPECTED_TICK_MINUTES` | `5` | Expected cron interval; `dead_orchestrator` alert fires when no tick line has appeared in 2× this value |

Per-plan overrides surfaced under `source: plan-state`:

- `auto_recommended` — per-plan version of `ORCH_AUTO_RECOMMENDED`
- `auto_merge_overrides.<task_n>` — set to `false` to mark a task
  sensitive (no `--auto` merge)

## Security model

The dashboard is built for a **single operator working locally**. It is
not hardened for multi-user or networked use.

- **Binds to `127.0.0.1` only.** Hardcoded. `create_app()` raises
  `RuntimeError` if asked to bind anywhere else, and `dashboard.sh`
  refuses to start without that constraint. Do not change this.
- **No authentication.** Anyone with a process on the loopback
  interface can read the dashboard. On a single-user laptop this is the
  same trust boundary as `~/.gh/` or your shell history.
- **Read-only.** No mutation endpoints. Adding write endpoints would
  require an auth design that doesn't currently exist.
- **No remote port-forwarding.** If you need to view the dashboard from
  another machine, tunnel over SSH (`ssh -L 5174:127.0.0.1:5174 ...`)
  and restrict the SSH source IP. Do NOT proxy through a public
  reverse proxy.
- **Command-line redaction.** The workers panel scrubs `KEY=VALUE`
  tokens whose KEY looks secret-bearing before displaying. Redaction is
  intentionally over-broad — better a false-positive `<redacted>` than
  a real token leaked to a screen-share.

## Endpoint reference

All endpoints return the same envelope:

```json
{ "data": <panel-specific or null>, "stale_at": "<iso8601>", "error": <string or null> }
```

`data: null` means "no data yet" (e.g. no in-progress plan), not an
error. `error: <string>` means something went wrong fetching — the
frontend renders the error in that panel only and keeps polling
other panels.

| Endpoint        | Method | Query params                     | Source                                  |
|-----------------|--------|----------------------------------|-----------------------------------------|
| `/api/healthz`  | GET    | —                                | trivial liveness probe                  |
| `/api/board`    | GET    | —                                | unified Mission Centre payload — composes columns + workers + plan status + cost + log tail + activity + github via `api_board.build_board` |
| `/api/alerts`   | GET    | —                                | blocked tasks + `orch:needs-robbie` PRs + `monitor:finding` issues + dead-orch detector |
| `/api/plan`     | GET    | —                                | newest `*.state.json` with `in_progress` |
| `/api/logs`     | GET    | `lines`, `since`, `include_rotated` | `.claude/state/orchestrator.log`    |
| `/api/github`   | GET    | —                                | `gh issue list` + `gh pr list` (30s cache; `ci_state` per PR) |
| `/api/workers`  | GET    | —                                | `ps` + active-worktrees manifest (each worker carries a `last_log` line) |
| `/api/config`   | GET    | —                                | env + settings.json + plan state        |

### Examples

```bash
curl http://127.0.0.1:5174/api/healthz
# → {"data": {"ok": true}, "error": null, "stale_at": "..."}

curl 'http://127.0.0.1:5174/api/logs?lines=20'
# → last 20 log lines with parsed level + ts

curl 'http://127.0.0.1:5174/api/logs?lines=3000'
# → {"data": null, "error": "too many lines requested (max 2000)", ...}

curl http://127.0.0.1:5174/api/alerts
# → {"data": {"alerts": [{"id": "blocked:...", "severity": "error", ...}, ...]}, ...}
```

## Stopping the dashboard

```bash
./.claude/scripts/dashboard.sh stop
```

Fallback if the launcher's bookkeeping gets out of sync:

```bash
kill "$(cat .claude/state/dashboard.pid)" && rm .claude/state/dashboard.pid
```

If the dashboard wedged and the PID file is stale, `dashboard.sh start`
removes the stale file automatically. Truly orphaned processes can be
found via `pgrep -f 'dashboard/app.py'`.

## Files

```
.claude/scripts/
  dashboard.sh                   — launcher (start|stop|status|restart)
  dashboard/
    __init__.py
    app.py                       — Flask factory + blueprint auto-discovery; / → Mission Centre, /dashboard → legacy
    requirements.txt             — Flask>=3.0,<4.0
    api_board.py                 — /api/board (Mission Centre unified payload)
    api_costs.py                 — token + USD rollup, used by /api/board
    api_plan.py                  — /api/plan
    api_logs.py                  — /api/logs
    api_github.py                — /api/github
    api_workers.py               — /api/workers (now includes last_log per worker)
    api_config.py                — /api/config
    templates/
      board.html                 — Mission Centre landing template (served at /)
    static/
      index.html                 — legacy 6-panel view (served at /dashboard)
      dashboard.js               — legacy frontend
      style.css                  — legacy styles
      board.js                   — Mission Centre frontend
      board.css                  — Mission Centre styles
      agents.json                — 20 worker names + Argus
      blocked_jokes.json         — joke pool for Blocked-column cards

.claude/state/                    (runtime — gitignored)
  dashboard.pid
  dashboard-venv/
  dashboard.log
```

## Adding a new endpoint

Drop a file under `.claude/scripts/dashboard/api_<name>.py` that exports
a top-level `bp = Blueprint(...)`. The factory in `app.py` globs for
`api_*.py` siblings and registers each `bp` automatically — no edit to
`app.py` required.

Convention: return responses via `dashboard.app.json_envelope(data=...,
error=...)` so the frontend's renderer can treat every panel uniformly.

After adding an endpoint, append its row to the **Endpoint reference**
table above and to the JSON contract in `static/dashboard.js`'s
comment header.
