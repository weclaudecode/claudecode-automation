# PLAN-04 — Dashboard UX Tier 1

Tier 1 of the dashboard UX review (see
`orchestrator-kit/docs/DASHBOARD-UX-REVIEW.md`). Turns the dashboard
from a passive readout into an operator console by surfacing the
high-signal items the kit already tracks but currently buries:
**blocked tasks, `orch:needs-robbie` PRs, monitor findings, dead-
orchestrator detection**, plus per-PR **CI status** and inline
**remediation hints** next to errors and blocked states.

Scope is intentionally narrow. Tier 2 (layout rebalance, log filter,
task-row drawer) and beyond are out of scope for this plan and will
land in follow-up plans once Tier 1 is in production.

All `touches:` paths reference the kit source tree
(`orchestrator-kit/.claude/scripts/dashboard/...`). The orchestrator
runs in this repo as its own dogfood substrate; workers modify the
kit source, the changes flow back via PRs, and the installed root
copy is reconciled by `kit-upgrade.sh` in a follow-up step (not part
of this plan).

## Task 1: Add /api/alerts endpoint
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/api_alerts.py`]

Greenfield Flask blueprint at `api_alerts.py` exposing `GET /api/alerts`.
Auto-discovered by `app.py` because the filename matches `api_*.py`.

The endpoint returns a list of alert dicts under the standard
`json_envelope` shape. Each alert has:

```python
{
  "id": "<stable hash>",          # for frontend dedupe
  "severity": "warn" | "error" | "info",
  "kind": "blocked" | "needs_robbie" | "monitor" | "dead_orchestrator",
  "summary": "<one-line operator-readable description>",
  "detail": "<optional longer text, e.g. blocked_reason>",
  "link": "<gh URL or null>",
  "since": "<iso8601 or null>",   # how long this alert has existed
  "suggested_action": "<short text, e.g. 'reset task 7' / 'merge PR #142' / 'check cron'>",
}
```

Four collectors, each running independently and never raising past the
top-level handler (failures in one source must not blank the others):

1. **`blocked` tasks** — read the active state file (newest
   `*.state.json` with `status: in_progress`); emit one alert per
   task whose `status == "blocked"`, severity `error`, detail =
   `blocked_reason`, suggested action quotes the "Resuming a blocked
   plan" jq snippet from `orchestrator-kit/README.md`.
2. **`needs_robbie` PRs** — `gh pr list --label orch:needs-robbie
   --state open --json number,title,url,createdAt`; emit one alert
   per PR, severity `warn`, link to PR.
3. **`monitor` findings** — `gh issue list --label monitor:finding
   --state open --json number,title,labels,url,createdAt`; emit one
   alert per finding, severity `info` (or `warn` if a heuristic
   `H1`/`H2`/`H4` is detected in title), link to issue.
4. **`dead_orchestrator`** — read `.claude/state/orchestrator.log`
   (and rotated logs only if current is empty); find the last
   `=== tick <iso> ===` marker; if `now - tick_ts > 2 * expected_interval`
   (assume 5 min default; allow override via `ORCH_DASHBOARD_EXPECTED_TICK_MINUTES`
   env var, default 5), emit ONE alert with severity `error`, summary
   "no orchestrator tick in X minutes — is cron running?",
   suggested_action "check crontab / launchd / `/loop` runner".

Reuse the 30 s in-memory cache pattern from `api_github.py` for the
two `gh` shells. The state-file read and the log tail are cheap; cache
those too (~10 s) just to keep CPU low under the 5 s poll.

Errors from individual collectors must be caught and surfaced via the
envelope's `error` field as a soft warning (`"alerts.gh: timeout
after 10s"`), not by raising — the alerts strip is a "show what you
can" surface, not a fail-fast contract.

Add the row to the **Endpoint reference** table in
`DASHBOARD.md` only in Task 4 (this task does not touch docs).

Tests: pytest under `orchestrator-kit/tests/dashboard/test_api_alerts.py`
if a tests dir exists; otherwise add inline `if __name__ == "__main__":`
self-check that builds a temp state file with a blocked task and asserts
the alert is emitted. Do not add a new test framework dependency.

Commit message: `feat(dashboard): add /api/alerts endpoint`.

## Task 2: Add CI rollup to /api/github
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/api_github.py`]

Extend the existing `gh pr list` call with `statusCheckRollup`. Add a
new `ci_state` field per PR object in the response, drawn from the
rollup. Values: `"SUCCESS"`, `"FAILURE"`, `"PENDING"`, or `null` when
there are no checks configured.

Concretely:

```python
rc, out, err = _run_gh([
    "pr", "list",
    "--repo", repo,
    "--state", "all",
    "--json", "number,title,state,mergedAt,url,statusCheckRollup",
    "--limit", "30",
])
```

In the reshape step, derive `ci_state` from `statusCheckRollup`:
- If the field is an empty list or missing → `None`
- Else aggregate: any `"FAILURE"` or `"ERROR"` → `"FAILURE"`;
  else any `"PENDING"` or `"IN_PROGRESS"` → `"PENDING"`;
  else `"SUCCESS"`.

Preserve the existing response shape additively — frontend code that
doesn't know about `ci_state` must continue to render unchanged.

Cache TTL stays at 30 s. Sort order unchanged.

Tests: extend the self-check pattern used in this file (or
`test_api_github.py` if one exists) to verify `ci_state` derivation
against three fixture rollups. No new dependencies.

Commit message: `feat(dashboard): add ci_state to /api/github PRs`.

## Task 3: Frontend alerts strip, remediation hints, and CI dot
**depends_on:** [1, 2]
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/static/index.html`, `orchestrator-kit/.claude/scripts/dashboard/static/dashboard.js`, `orchestrator-kit/.claude/scripts/dashboard/static/style.css`, `orchestrator-kit/.claude/scripts/dashboard/static/runbook.js`]

Three coordinated frontend changes that land together because they
share `dashboard.js` and `style.css`:

### 3a. Alerts strip
Insert a new `<section id="alerts-strip" data-strip="alerts">`
between `<header class="topbar">` and `<main class="grid">` in
`index.html`. The strip renders alert cards horizontally on wide
screens, stacks on narrow.

`dashboard.js`: add `renderAlerts(data)` that fetches `/api/alerts`
via the existing `fetchPanel` plumbing (treat the strip as a 6th
panel for polling purposes). Each alert renders as a compact card:

```
[severity-icon]  <summary>                        <since>  [action]
                 <detail (collapsed by default)>
```

- Icon per severity: ❗ error, ⚠ warn, ⓘ info (use plain text glyphs;
  no icon font dependency).
- `<action>` is a button that copies `suggested_action` to clipboard
  AND, if `link` is set, opens it in a new tab. Use the existing
  `escape` helper for all dynamic values.
- A collapse/expand toggle on the whole strip; default-expanded if
  any alert has severity `error`, default-collapsed otherwise.
- Empty state: hide the strip entirely (do NOT render an empty box).

### 3b. Remediation hints (runbook.js)
New file `static/runbook.js` exporting a `RUNBOOK` map of well-known
error / state strings to short remediation snippets. Keys cover at
minimum:

- `worker_failed_3x` → reset-task jq snippet from kit README
- `pr_closed_unmerged` → triage flow
- `review_iter_cap` → reset retries + remove orch:review-blocked
- `upstream_blocked_t<N>` → clear-cascade jq snippet
- `gh CLI not found` → `brew install gh && gh auth login`
- `ps timed out` → check loadavg, restart dashboard

Wire it into `dashboard.js`:
- When a task row shows `blocked_reason`, append a `❓` help icon
  that toggles a popover beneath the row with the runbook snippet.
- When a panel renders an error div, append the same `❓` icon with
  the matching snippet (if any matches by substring).
- Popovers close on Escape or outside-click.

### 3c. CI status dot in PR rows
Modify `renderGithub` to render a coloured dot before each PR title
based on `ci_state`:

| ci_state    | Glyph | Colour              |
|-------------|-------|---------------------|
| `SUCCESS`   | ●     | `--status-merged`   |
| `FAILURE`   | ●     | `--status-blocked`  |
| `PENDING`   | ◐     | `--status-in_review`|
| `null`/missing | —  | `--fg-dim`          |

The dot has a tooltip (`title="CI: failure"`) for accessibility.

### CSS additions (style.css)
- `#alerts-strip` layout (flex, gap, padding matching `.grid`)
- `.alert-card` with severity-tinted left border (4 px)
- `.alert-card.error` / `.warn` / `.info` background tints
- `.ci-dot` inline-block, 8 px, vertical-aligned
- `.help-icon` + `.runbook-popover` styles
- Keep all colours referencing existing `--status-*` and `--fg-*`
  custom properties — no new palette.

Accessibility:
- Add `role="status" aria-live="polite"` to `#alerts-strip` so screen
  readers announce new alerts.
- `help-icon` is a `<button>` with `aria-expanded` + `aria-controls`.

Tests: open `dashboard.sh start` locally, manually verify:
1. Strip appears when at least one alert is present and hides cleanly when empty.
2. Help icon next to a blocked task pops the correct runbook snippet.
3. PR rows show a coloured dot when `ci_state` is set.

Commit message: `feat(dashboard): alerts strip, runbook hints, CI dot`.

## Task 4: Documentation update
**depends_on:** [3]
**touches:** [`orchestrator-kit/docs/DASHBOARD.md`]

Bring `DASHBOARD.md` current with the changes from tasks 1-3:

- Add an **Alerts strip** subsection under "What each panel shows"
  describing the 4 alert kinds, severity meanings, and the empty/
  collapsed states.
- Append `/api/alerts` row to the **Endpoint reference** table with
  a one-line description.
- Append a **Runbook hints** subsection explaining how the `❓` icons
  work and listing the keys in `runbook.js` so operators can search
  for the snippet they want.
- Append a row for the `ORCH_DASHBOARD_EXPECTED_TICK_MINUTES` env var
  to the **Tunables** table.
- Brief mention of the `ci_state` field in the Issues + PRs panel
  description.

No README changes in this task — the root `README.md`'s "What's
included" already mentions the dashboard; if a sentence-level update
is warranted it'll be a separate doc PR after the UX work is
visible.

Commit message: `docs(dashboard): document alerts strip + runbook + CI dot`.
