---
auto_recommended: true
---

# PLAN-03 — local Flask dashboard

A local-only web dashboard that surfaces the orchestrator's live state to
the operator without leaving the terminal: plan progress, recent log
output, GitHub issues + merged PRs, active workers, and effective
configuration. Served by a tiny Flask app from inside the installed kit;
binds to `127.0.0.1` only; no auth (single-operator local tool).

Plan uses the kit's `PLAN-NN-<slug>.md` format and ingests cleanly. As
with PLAN-02, it's intended for **orchestrator-driven execution in the
dogfood target** (`claudecode-automation-v2`) where the kit is installed
at root. The kit itself is the SOURCE; all `touches:` paths reference
the `orchestrator-kit/` source tree, so workers running in v2 modify the
kit-source files via worktrees and the changes flow back to
`weclaudecode/claudecode-automation` via PRs.

## Orchestrator scenarios covered

- **5-way parallel fan-out:** tasks 3 + 4 + 5 + 6 + 7 each own a single
  endpoint file under `dashboard/api_*.py` — fully disjoint touches, so
  `MAX_PARALLEL=5` (or higher) lets them run concurrently after task 1
  lands.
- **Dep chain:** 1 → {2, 3, 4, 5, 6, 7} → 8. Frontend (task 2) develops
  in parallel against assumed schemas; endpoints (3-7) emit those
  schemas; task 8 reconciles docs after everything lands.
- **No sensitive flags expected:** all tasks create new files under a
  new `.claude/scripts/dashboard/` subtree or append to existing
  README/docs. No IAM, no migrations, no edits to orchestrator core
  scripts. `auto_recommended: true` lets workers pick reasonable
  defaults (port number, polling interval, panel ordering) without
  escalation; every choice is logged to `.claude/state/decisions.md`.

## Architecture (target)

```
orchestrator-kit/.claude/scripts/
  dashboard.sh                   — launcher: venv setup + Flask start/stop
  dashboard/
    __init__.py                  — empty
    app.py                       — Flask factory; blueprint auto-discovery
    requirements.txt             — Flask + gunicorn (or stdlib WSGI)
    api_plan.py                  — /api/plan       (state.json reader)
    api_logs.py                  — /api/logs       (orchestrator.log tail)
    api_github.py                — /api/github     (gh CLI wrapper, cached)
    api_workers.py               — /api/workers    (ps + worktree manifest)
    api_config.py                — /api/config     (env + settings.json)
    static/
      index.html                 — single-page layout, 6 panels
      dashboard.js               — fetch loop, panel renderers
      style.css                  — grid layout, minimal style
```

Runtime state (created at dashboard launch, gitignored):

```
.claude/state/
  dashboard.pid                  — running Flask PID (for dashboard.sh stop)
  dashboard-venv/                — Python venv with Flask installed
  dashboard.log                  — Flask stdout/stderr
```

Key design constraints:

- **Localhost bind only.** Flask `app.run(host="127.0.0.1", ...)`. Never
  `0.0.0.0`. Hardcoded — not a tunable. The reviewer should reject any
  PR that exposes the dashboard on a non-loopback interface.
- **Read-only.** All endpoints are GET. No POST/PUT/DELETE. The
  dashboard observes the orchestrator; it does not control it.
- **No auth.** Single-operator local tool. Documented in DASHBOARD.md.
- **Blueprint auto-discovery.** `app.py` globs `api_*.py` and registers
  each module's `bp` blueprint. This is what unlocks parallel endpoint
  development (tasks 3-7 each add their own file; no touches collision
  on `app.py`).
- **Polling, not streaming.** Frontend polls each endpoint every 5s
  (configurable). No WebSockets, no SSE — keeps the backend trivial.
- **JSON contract per panel:** each endpoint returns
  `{ "data": <panel-specific>, "stale_at": <iso8601>, "error": null }`.
  Frontend renders `error` if non-null; otherwise renders `data`.

---

## Task 1: dashboard scaffold + launcher + blueprint auto-discovery
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/dashboard.sh`, `orchestrator-kit/.claude/scripts/dashboard/__init__.py`, `orchestrator-kit/.claude/scripts/dashboard/app.py`, `orchestrator-kit/.claude/scripts/dashboard/requirements.txt`]

Lay down the Flask backbone that tasks 2-7 each plug into. No endpoints
or frontend yet — task 1 ships only the scaffold + launcher.

Steps:

1. Create `orchestrator-kit/.claude/scripts/dashboard/__init__.py` (empty).

2. Create `orchestrator-kit/.claude/scripts/dashboard/requirements.txt`:
   - `Flask>=3.0,<4.0`
   - No gunicorn — Flask's dev server is fine for a single-operator
     local tool; one less moving part.

3. Create `orchestrator-kit/.claude/scripts/dashboard/app.py`:
   - `create_app()` factory.
   - `JSON_RESPONSE_TEMPLATE = {"data": None, "stale_at": ..., "error": None}`
     helper.
   - Blueprint auto-discovery: `glob.glob` for `api_*.py` in the
     dashboard directory, import each module, `app.register_blueprint(mod.bp)`.
     Catch `ImportError` per-module with a warning log — a half-installed
     endpoint shouldn't crash the whole app.
   - `/` route serves `static/index.html` (will 404 until task 2 lands;
     that's fine — task 1 only verifies the server starts).
   - Bind explicitly to `127.0.0.1`. Refuse to start if `host` is anything
     else (defensive).
   - Port from `ORCH_DASHBOARD_PORT` env var, default `5174`.

4. Create `orchestrator-kit/.claude/scripts/dashboard.sh`:
   - `start` subcommand: create venv at `.claude/state/dashboard-venv/`
     if missing, `pip install -r requirements.txt` in it, launch Flask
     in background, write PID to `.claude/state/dashboard.pid`,
     redirect stdout/stderr to `.claude/state/dashboard.log`.
   - `stop` subcommand: read PID, kill, remove PID file.
   - `status` subcommand: read PID, check `kill -0`, print
     `running (pid N, port P)` or `stopped`.
   - `restart` subcommand: stop + start.
   - Refuse to bind to anything other than `127.0.0.1` — even if
     `ORCH_DASHBOARD_HOST` is set (intentionally NOT supported).
   - chmod 755.

5. Smoke test: `./dashboard.sh start` → curl
   `http://127.0.0.1:5174/api/healthz` (Flask's default if you add a
   trivial blueprint inline) → expect 200. `./dashboard.sh stop`.
   Document this in `dashboard.sh --help` output.

6. Add to README's gitignore block:
   - `.claude/state/dashboard.pid`
   - `.claude/state/dashboard-venv/`
   - `.claude/state/dashboard.log`

   (Task 8 propagates these to the canonical README install section; for
   now, just ensure the dashboard's own files reference them correctly.)

Acceptance: `./dashboard.sh start` starts Flask cleanly, `./dashboard.sh
status` reports running, `./dashboard.sh stop` cleans up. No endpoints
registered yet — visiting `/` returns 404, which is expected.

## Task 2: frontend HTML + CSS + polling JS shell
**depends_on:** [1]
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/static/index.html`, `orchestrator-kit/.claude/scripts/dashboard/static/dashboard.js`, `orchestrator-kit/.claude/scripts/dashboard/static/style.css`]

Single-page dashboard. Develops in parallel against endpoint schemas
defined in this task's contract block (tasks 3-7 must match these
schemas).

Steps:

1. Create `index.html`:
   - 6 panels in a CSS grid: Plan Status, Logs, Issues + PRs, Workers,
     Config, plus a header strip with active plan slug + tick counter.
   - Each panel is a `<section data-panel="plan|logs|github|workers|config">`
     with a `<header>` (title + last-updated timestamp) and a `<div
     class="content">` (renderer target).
   - Inline `<script src="dashboard.js">` at end of body.

2. Create `style.css`:
   - CSS grid for 6 panels, responsive collapse to 2-column at <1000px,
     1-column at <600px.
   - Monospace font throughout (this is an operator tool, not consumer).
   - Color-code task statuses: pending=gray, in_progress=blue,
     in_review=yellow, merged=green, blocked=red.
   - Log panel: scrollable, max-height with virtual-scroll-ish behaviour
     (last 200 lines visible, auto-scroll to bottom unless user scrolled
     up).

3. Create `dashboard.js`:
   - `POLL_INTERVAL_MS = 5000`.
   - On load, fetch each endpoint in parallel and render its panel.
   - Set up `setInterval` to repoll each endpoint every 5s.
   - Per-panel renderer functions: `renderPlan(data)`, `renderLogs(data)`,
     `renderGithub(data)`, `renderWorkers(data)`, `renderConfig(data)`.
   - Error handling: if any endpoint returns `{error: <string>}` or
     fetch fails, render error state in that panel only (others keep
     polling). Don't crash the whole page.
   - Refresh button per panel + global pause-polling toggle.

4. **JSON contract block (endpoints must match):**

   ```
   /api/plan       → { data: {
                         plan_file, slug, total_tasks, status,
                         ingested_at, tasks: [{n, title, status,
                         depends_on, touches, issue, pr, retries,
                         blocked_reason?, merged_at?}]
                       }, stale_at, error }

   /api/logs       → { data: {
                         lines: [{ts, level, msg}],
                         total_lines, since
                       }, stale_at, error }

   /api/github     → { data: {
                         open_issues: [{number, title, labels, url}],
                         recent_prs: [{number, title, state, merged_at, url}]
                       }, stale_at, error }

   /api/workers    → { data: {
                         processes: [{pid, started_at, cmdline}],
                         active_worktrees: [{path, branch, task_n}]
                       }, stale_at, error }

   /api/config     → { data: {
                         tunables: [{name, source, current, default, description}]
                       }, stale_at, error }
   ```

Acceptance: open `http://127.0.0.1:5174/` in a browser, see the 6-panel
layout. Each panel shows "loading..." and after 5s either renders or
shows an error (depending on whether the endpoint exists yet). Polling
continues without page-crash on individual endpoint failure.

## Task 3: /api/plan endpoint
**depends_on:** [1]
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/api_plan.py`]

Read the active plan's state.json and emit it in the shape the frontend
expects.

Steps:

1. Create `api_plan.py` with a Flask `Blueprint("plan", __name__)` named
   `bp` (matches auto-discovery contract).

2. Find the active plan: glob `.claude/plans/*.state.json`, filter where
   `.status == "in_progress"`, pick newest by mtime. Mirror
   `orchestrator.sh`'s `STATE_FILE` lookup (lines ~94-96).

3. Parse with `json.load` and reshape to match the contract from task 2:
   - Top-level fields direct-copy.
   - `tasks` dict → ordered list of `{n: int, title, status, ...}`.
   - Include `merged_at` and `blocked_reason` only when present.

4. If no in-progress plan, return `{"data": null, "stale_at": now,
   "error": null}` (not an error — just nothing to show).

5. Catch JSON parse errors and missing state file gracefully: return
   `{"data": null, "stale_at": now, "error": "..."}`.

Acceptance: `curl http://127.0.0.1:5174/api/plan` returns JSON matching
the contract when an in-progress plan exists; returns `data: null`
otherwise. Frontend plan panel renders.

## Task 4: /api/logs endpoint
**depends_on:** [1]
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/api_logs.py`]

Tail the orchestrator log with range params.

Steps:

1. Create `api_logs.py` with `Blueprint("logs", __name__)` named `bp`.

2. Read `.claude/state/orchestrator.log` (and any rotated
   `orchestrator.log.YYYYMMDDTHHMMSSZ` if `?include_rotated=1`).

3. Parse query params:
   - `?lines=N` (default 200, max 2000) — last N lines.
   - `?since=<iso8601>` — only lines after this timestamp (parse the
     `=== tick YYYY-MM-DDTHH:MM:SSZ ===` markers).

4. Heuristic line-level parse:
   - Lines starting with `===` are tick boundaries.
   - Lines starting with `---` are phase boundaries.
   - Lines containing `warning:` or `error:` get `level: "warn|error"`.
   - Everything else `level: "info"`.
   - `ts` extracted from the most-recent `=== tick` line above.

5. Return `{"data": {"lines": [...], "total_lines": N, "since": ...},
   "stale_at": now, "error": null}`.

6. Hard size cap on response: if `total_lines > 2000` reject with
   `error: "too many lines requested"`.

Acceptance: `curl 'http://127.0.0.1:5174/api/logs?lines=50'` returns 50
lines as JSON with level + ts fields. Frontend logs panel renders with
color-coded levels.

## Task 5: /api/github endpoint
**depends_on:** [1]
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/api_github.py`]

Wrap `gh` CLI calls for issues + PRs with short cache.

Steps:

1. Create `api_github.py` with `Blueprint("github", __name__)` named `bp`.

2. Detect repo via `gh repo view --json nameWithOwner -q .nameWithOwner`
   (subprocess). Cache for the lifetime of the Flask process.

3. Two `gh` calls per request (or cached):
   - `gh issue list --repo $REPO --state open --json
     number,title,labels,url --limit 50`
   - `gh pr list --repo $REPO --state all --json
     number,title,state,mergedAt,url --limit 30`

4. In-memory cache with 30s TTL. Avoid hammering `gh` on every 5s poll.

5. Return shape per contract:
   `{open_issues: [...], recent_prs: [...]}`.
   - `merged_at` from `mergedAt` (camelCase from `gh`).
   - Sort `open_issues` by number desc.
   - Sort `recent_prs` by merged-then-state, then number desc.

6. On `gh` failure (auth lost, network), return `error:
   "<stderr>"` with `data: null`.

7. **No tokens in logs.** `subprocess.run` with `capture_output=True`;
   never log the full env. `gh` reads its own keyring.

Acceptance: `curl http://127.0.0.1:5174/api/github` returns recent
issues + PRs as JSON. Repeated calls within 30s return identical
payload (cache hit — log this for verification). Frontend GitHub panel
renders both lists.

## Task 6: /api/workers endpoint
**depends_on:** [1]
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/api_workers.py`]

List active `claude -p` worker processes + active worktrees.

Steps:

1. Create `api_workers.py` with `Blueprint("workers", __name__)` named `bp`.

2. Process discovery: `ps -axo pid,lstart,command` then filter for
   `claude` with `-p` or `--print` in cmdline. Don't shell-out a full
   `ps aux | grep` (PATH issues, race with self-match). Use
   `subprocess.run(["ps", ...], capture_output=True)` and parse.

3. Worktree discovery: read `.claude/state/active_worktrees.txt`
   (orchestrator's manifest — see `_dispatcher_lib.sh`
   `register_worktree`). Each line is `<path>\t<branch>\t<task_n>`.
   Filter to entries whose path still exists on disk.

4. Cross-reference: if a process's cwd matches a worktree path, mark
   them as linked. (Optional polish — only if `psutil` is acceptable;
   otherwise skip cross-ref and let frontend join on `task_n` if
   possible.)

   **Decision:** do NOT add psutil as a dep. Stick to `ps`. Cross-ref is
   nice-to-have, not required.

5. Return shape per contract: `{processes: [...], active_worktrees: [...]}`.

6. Sanitize cmdline: strip env-var prefixes that might contain secrets
   (`AWS_*`, `GITHUB_TOKEN`, etc.) before returning. Safer to over-redact.

Acceptance: `curl http://127.0.0.1:5174/api/workers` returns active
worker PIDs + active worktrees. When the orchestrator is mid-tick with a
worker spawned, the worker appears. When idle, both lists empty.
Frontend workers panel renders.

## Task 7: /api/config endpoint
**depends_on:** [1]
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/api_config.py`]

Introspect tunables and emit a structured config view — current value,
default, source, and description.

Steps:

1. Create `api_config.py` with `Blueprint("config", __name__)` named `bp`.

2. Define the **canonical tunable list** (hardcoded in this file —
   it's the source of truth for which knobs the dashboard surfaces):

   ```python
   TUNABLES = [
       ("ORCH_MAX_PARALLEL",    "1",        "Max parallel workers per tick"),
       ("ORCH_WORKER_MODEL",    "sonnet",   "Claude model (sonnet|opus)"),
       ("ORCH_MAX_TURNS",       "30",       "claude -p --max-turns cap"),
       ("ORCH_AUTO_RECOMMENDED","0",        "Default auto-resolve for ambiguous decisions"),
       ("ORCH_LOG_MAX_BYTES",   "10485760", "Log rotation threshold (bytes)"),
       ("ORCH_DASHBOARD_PORT",  "5174",     "Dashboard Flask port"),
   ]
   ```

3. For each tunable, resolve `current` and `source`:
   - If set in `os.environ`, `source: "env"`, `current: <env value>`.
   - Else `source: "default"`, `current: <default>`.

4. Also include `settings.json` keys from `.claude/settings.json`
   (read-only display — show the hook configuration but don't editing
   surface). Tag these as `source: "settings.json"`.

5. Include per-plan overrides from the active state.json:
   - `auto_recommended` (per-plan field).
   - `auto_merge_overrides` (task-level).
   Tag as `source: "plan-state"`.

6. Return shape per contract: `{tunables: [{name, source, current,
   default, description}, ...]}`.

7. **Read-only.** No mutation endpoints. Documented in DASHBOARD.md.

Acceptance: `curl http://127.0.0.1:5174/api/config` returns the
canonical tunable list with current values resolved. Frontend config
panel renders a table.

## Task 8: docs + README install hook
**depends_on:** [1, 2, 3, 4, 5, 6, 7]
**touches:** [`orchestrator-kit/docs/DASHBOARD.md`, `orchestrator-kit/README.md`]

Wrap the dashboard with operator docs and update the kit's README.

Steps:

1. Create `orchestrator-kit/docs/DASHBOARD.md`:
   - **Quick start:** `./dashboard.sh start`, open
     `http://127.0.0.1:5174/`, `./dashboard.sh stop`.
   - **What each panel shows** — short paragraph per panel.
   - **Tunables** — table mirroring the `TUNABLES` constant in
     `api_config.py`. Note: keep this table in sync manually when
     adding new tunables; a CI check is out of scope for v1.
   - **Security model** — explicit:
     - Binds to `127.0.0.1` only. Refuses to start otherwise.
     - No auth. Local-operator tool. Do not port-forward over SSH
       without restricting source IPs.
     - Read-only. No mutation endpoints. Observability tool only.
   - **Endpoint reference** — `/api/plan`, `/api/logs`, etc. with
     example curl + response shape (link to JSON contract in task 2).
   - **Stopping the dashboard** — `./dashboard.sh stop`, or
     `rm .claude/state/dashboard.pid && kill <pid>` as fallback.

2. Update `orchestrator-kit/README.md`:
   - Add a "## Local dashboard" section after "## First run":
     ~10 lines, links to `docs/DASHBOARD.md`.
   - Append to the gitignore block in "Install into a repo":
     ```
     .claude/state/dashboard.pid
     .claude/state/dashboard-venv/
     .claude/state/dashboard.log
     ```
   - Add `python3` (>=3.11) to Prerequisites.
   - Mention the dashboard in the "Cost knobs" table (add
     `ORCH_DASHBOARD_PORT` row).

3. Smoke test before declaring done: in claudecode-automation-v2,
   `./dashboard.sh start`, visit `http://127.0.0.1:5174/`, verify all
   6 panels render (some may show "no active plan" — that's fine, as
   long as they don't error). Stop. Document any rough edges as
   follow-up issues with `agent-followup` label.

Acceptance: README and DASHBOARD.md are complete and consistent.
Operator can install the kit fresh, run `./dashboard.sh start`, and use
the dashboard without further configuration.
