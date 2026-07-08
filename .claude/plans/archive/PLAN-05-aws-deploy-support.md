# PLAN-05 — AWS / AgentCore deployment capability for the kit

Adds the autonomy boundary the kit is currently missing: today the kit handles
"worker writes code → reviewer approves → merge to main"; this plan adds the
second loop, "merged code → deploy to AWS → smoke-test → report." Plus the
plumbing required to do that safely — AWS env propagation, `cdk diff` as a
review artifact, per-stack deploy locks, post-deploy smoke tests, cost ceiling,
inter-plan ordering, multi-env context, and a manifest-to-plan generator that
lets one YAML manifest fan out into N tool tasks.

Scope: Tier 1 + Tier 2 + Tier 3 of the gap analysis discussed with the user
(items #1–#15, minus the GitLab CI path which is dropped — GitHub only).

All changes target the canonical kit source under `orchestrator-kit/`. The
running install at repo root is unaffected until the user runs the existing
`kit-upgrade.sh` sync. That separation is deliberate: a buggy mid-plan change
must not brick the running orchestrator executing the plan.

## Task 1: Extend PLAN-FORMAT.md with new fields
**depends_on:** []
**touches:** [`orchestrator-kit/docs/PLAN-FORMAT.md`]

Document all new task and frontmatter fields so subsequent tasks have a spec
to implement against. Add sections for:

- Task field `**deploy_mode:** operator | autonomous` (default `operator`).
- Task field `**smoke_test:** <shell command>` (one-line, runs after PR merge).
- Frontmatter `aws:` block with `account`, `region`, `profile`, `cdk_app_path`.
- Frontmatter `env: dev | staging | prod` (default `dev`).
- Frontmatter `requires: [PLAN-NN, ...]` for inter-plan ordering.
- Frontmatter `pre_flight:` with operator-gate issue title pattern.

Each section: syntax, semantics, validation rules, one worked example. Cross-link
the relevant implementation script (`ingest-plan.sh`, `orchestrator.sh`,
`launch-worker.sh`, etc.) so the spec doesn't drift. Acceptance: shellcheck N/A
(markdown); manual read-through confirms every field implemented in T2–T12 has
a corresponding spec section.

## Task 2: Extend ingest-plan.sh to parse new fields → state schema v3
**depends_on:** [1]
**touches:** [`orchestrator-kit/.claude/scripts/ingest-plan.sh`]

Bump state.json schema from v2 to v3. Parse:

- Frontmatter `aws:` (account/region/profile/cdk_app_path) → top-level
  `aws_env` object in state file.
- Frontmatter `env:` → top-level `env` string.
- Frontmatter `requires:` → top-level `requires` array of plan-NN strings.
- Frontmatter `pre_flight:` → top-level `pre_flight` object.
- Per-task `**deploy_mode:**` → `tasks.N.deploy_mode` ("operator"|"autonomous").
- Per-task `**smoke_test:**` → `tasks.N.smoke_test` (string).

Use the existing `gawk` pattern (required dep already declared). Default
`deploy_mode = "operator"` when absent. Reject unknown frontmatter keys with
a clear error (silent-acceptance is the exact failure mode this kit hates —
see `project_kit_safety_findings`). Acceptance: existing PLAN-02 and PLAN-04
fixtures still ingest cleanly (back-compat); a new fixture exercising every
new field ingests with the right state.json shape.

## Task 3: Skill-presence preflight in check-preconditions.sh
**depends_on:** [2]
**touches:** [`orchestrator-kit/.claude/scripts/check-preconditions.sh`]

When the active plan's state file has an `aws_env` block, require additional
plugins to be installed: `aws-core`, `aws-agents` always; `cdk-agentcore`,
`agentcore-deploy-runbook`, `agentcore-architect` when any task body or plan
prose mentions agentcore / AgentCore. Use `claude plugin list` to detect;
exit non-zero with a clear "install: claude plugin install <name>" message
per missing plugin. Acceptance: against a plan with `aws:` block but no
plugins, exits 1 listing what's missing; with plugins installed, exits 0.

## Task 4: pre_flight operator gate in orchestrator.sh
**depends_on:** [2]
**touches:** [`orchestrator-kit/orchestrator.sh`, `orchestrator-kit/.claude/scripts/preflight-gate.sh`]
**auto_merge:** false

If the active plan's state has a `pre_flight` block, the tick checks for a
matching open GitHub issue (title from `pre_flight.issue_title`). Issue open →
tick no-ops with a one-line log "preflight: waiting on issue #N". Issue closed
→ tick proceeds. If no issue exists yet, create one whose body is the checklist
items from `pre_flight.checklist` and exit. New script `preflight-gate.sh`
encapsulates the logic; orchestrator.sh calls it at top of tick after lock
acquisition but before phase 1. Acceptance: with an open preflight issue,
ticks no-op cleanly; closing the issue lets the next tick proceed.

## Task 5: AWS env propagation in launch-worker.sh + worker prompt
**depends_on:** [2]
**touches:** [`orchestrator-kit/.claude/scripts/launch-worker.sh`, `orchestrator-kit/.claude/prompts/worker-superpower.md`]

When state.json has an `aws_env` block, `launch-worker.sh` exports
`AWS_PROFILE`, `AWS_REGION` (and `AWS_DEFAULT_REGION`), `CDK_DEFAULT_ACCOUNT`,
`CDK_DEFAULT_REGION` into the worker's `claude -p` environment. Worker prompt
gets a new section "AWS context" that explains the env vars are pre-set,
references `aws-agents:agents-deploy` and `cdk-agentcore` skills as
authoritative for any cdk/agentcore decisions, and forbids the worker from
grepping YAML for region (it's in env). Acceptance: a smoke task asserts the
env vars are set inside the worker; worker prompt reads cleanly.

## Task 6: cdk diff as a PR review artifact
**depends_on:** [5]
**touches:** [`orchestrator-kit/.claude/scripts/cdk-diff.sh`, `orchestrator-kit/.claude/scripts/review-pr.sh`]
**max_turns:** 50

New script `cdk-diff.sh <pr-number>`: checks out PR head, runs `cdk diff` per
stack in `aws_env.cdk_app_path`, captures output, posts as a PR comment with a
collapsed `<details>` block per stack. `review-pr.sh` invokes it before
dispatching the multi-agent review when the active plan has an `aws_env`
block; passes the diff text into the reviewer prompt so `code-reviewer`,
`silent-failure-hunter`, and `/security-review` see the actual cloud delta.
Acceptance: against a sample CDK PR (Phase 0 fixture), diff comment appears
and matches `cdk diff` run manually.

## Task 7: Per-stack deploy lock helpers in _dispatcher_lib.sh
**depends_on:** [2]
**touches:** [`orchestrator-kit/.claude/scripts/_dispatcher_lib.sh`]

Add two functions: `acquire_stack_lock <stack-name>` and
`release_stack_lock <stack-name>`. Lock dir at
`.claude/state/cdk-stack-locks/<stack-name>.lock.d/` with PID file; stale-PID
break mirrors the existing `state_write` lock pattern. Idempotent on same-PID
reacquire. Used by T8 (long-running deploy tracking) to serialize deploys that
touch the same CloudFormation stack. Acceptance: parallel-test shell script
runs two `acquire_stack_lock foo` from different PIDs; second blocks; first
releases; second proceeds.

## Task 8: Long-running deploy tracking (deploy-watch phase)
**depends_on:** [5, 7]
**touches:** [`orchestrator-kit/.claude/scripts/deploy-watch.sh`, `orchestrator-kit/orchestrator.sh`]
**auto_merge:** false
**max_turns:** 50

For tasks where `tasks.N.deploy_mode == "autonomous"`, worker disowns
`cdk deploy <stack> 2>&1 | tee deploy.log` and writes
`.claude/state/deploy-status-<task>.json` with `{pid, stack, started_at,
status: "running"}`. New script `deploy-watch.sh` runs as orchestrator phase
8 (between monitor-sweep and lock release): checks each status file, updates
to `succeeded`/`failed` based on PID liveness + log tail, posts result as PR
comment, releases the stack lock, and marks the task `merged` or `blocked`.
Workers do NOT wait for `cdk deploy` to finish (that exceeds `--max-turns`).
Acceptance: a synthetic `sleep 60; exit 0` task simulating a deploy goes from
running → succeeded across ticks without the worker timing out.

## Task 9: Post-deploy smoke-test in post-merge-check.sh
**depends_on:** [2]
**touches:** [`orchestrator-kit/.claude/scripts/post-merge-check.sh`]

After CI goes green on a merged PR, if the task's state row has a
`smoke_test` field, run it with the plan's AWS env exported, capture stdout
and exit code. Non-zero exit → label PR `orch:smoke-failed`, post failure
comment, file blocker issue cascading to dependents. Zero exit → label
`orch:smoke-ok` and proceed normally. Hard-cap smoke_test runtime at 5
minutes (configurable via `ORCH_SMOKE_TIMEOUT_S`). Acceptance: a smoke
command of `exit 0` labels the PR ok; `exit 1` labels failed and creates
blocker issue.

## Task 10: Cost ceiling pre-tick check
**depends_on:** [2]
**touches:** [`orchestrator-kit/.claude/scripts/cost-check.sh`, `orchestrator-kit/orchestrator.sh`]

New script `cost-check.sh` runs once per tick (cached for 10 min) when the
active plan has an `aws_env` block. Calls `aws ce get-cost-and-usage` for
month-to-date spend in the plan's account; if `$ORCH_COST_BUDGET_USD_PER_MONTH`
is set and projected month-end exceeds it (linear extrapolation), exit 1 and
emit a `cost-block` issue. orchestrator.sh runs `cost-check.sh` at top of
tick after preflight-gate; non-zero halts the tick. Belt-and-braces against
X-3 (runaway agent). Acceptance: with a low budget env var, tick halts and
files an issue; clearing the budget env var lets tick proceed.

## Task 11: Inter-plan ordering via requires field
**depends_on:** [2]
**touches:** [`orchestrator-kit/orchestrator.sh`, `orchestrator-kit/.claude/scripts/plan-promote.sh`]
**auto_merge:** false

orchestrator.sh's plan selection currently picks the newest `in_progress`
state file. Wrap that in `plan-promote.sh`: for each candidate plan, if its
state file has `requires: [PLAN-NN, ...]`, refuse to promote unless every
required plan has `status: done` in its archived state file. A plan with
unmet requires stays in `in_progress` but does no work and logs
"plan PLAN-X waiting on PLAN-Y". Acceptance: a synthetic two-plan setup where
PLAN-B `requires: [PLAN-A]` — ticks only progress A until A archives, then
switch to B.

## Task 12: Multi-env context (state file + lock namespacing)
**depends_on:** [2]
**touches:** [`orchestrator-kit/.claude/scripts/_dispatcher_lib.sh`, `orchestrator-kit/orchestrator.sh`]
**auto_merge:** false

When state.env is set (default `dev`), all lock paths and state files are
namespaced per env: `.claude/state/<env>/orchestrator.lock/`,
`.claude/state/<env>/cdk-stack-locks/`, etc. The plan file itself stays in
`.claude/plans/` unchanged. Same plan can be re-ingested per env (e.g.,
`PLAN-05` first against dev, then re-ingested against staging by editing
frontmatter `env: staging`). dev and staging ticks can run in parallel
because their locks are independent. Acceptance: two concurrent
`orchestrator.sh` ticks for `env: dev` vs `env: staging` both make progress
without contending on the orchestrator lock.

## Task 13: /agent-manifest-to-plan skill + slash command
**depends_on:** [1]
**touches:** [`orchestrator-kit/.claude/skills/agent-manifest-to-plan/**`, `orchestrator-kit/.claude/commands/agent-manifest-to-plan.md`]
**max_turns:** 50

New skill that reads a YAML agent manifest (e.g.,
`infrastructure/config/agents/xero_advisor_agent.yaml`) and emits a draft
PLAN-NN file. For each tool entry in the manifest, generates a task to
implement the tool Lambda + a task to add its Gateway target. Inherits
`aws:` frontmatter from a sensible default (operator can edit). Generates a
manifest-derived `touches` (per-tool `agents/<agent>/tools/<tool_name>/**`).
Models the design intent in PLAN.md §0.3 (D1–D24) and Phase 3 (12 tools).
Acceptance: against the xero-advisor manifest, produces an ingestable plan
with 13 tool tasks + shared toolbelt task; `ingest-plan.sh` accepts it
without manual edits.

## Task 14: Bedrock spend dashboard widget
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/scripts/dashboard/**`]

Add a tile to the local dashboard (`dashboard.sh` Python webapp) showing
Bedrock InvokeModel spend month-to-date for the configured AWS account, plus
a sparkline of daily spend over the last 14 days. Source: `aws ce
get-cost-and-usage` filtered by service `Amazon Bedrock`. Best-effort: if the
AWS CLI isn't installed or the account isn't configured, the tile shows
"n/a" rather than breaking the dashboard. Acceptance: tile renders against a
real account; degrades cleanly with no AWS creds.

## Task 15: agentcore-bundle.md reference skill
**depends_on:** []
**touches:** [`orchestrator-kit/.claude/skills/agentcore-bundle/**`]

New collated reference skill bundling the patterns workers reach for
repeatedly: Bedrock model IDs per region (US/AU/APAC inference profiles
table), SigV4 signing pattern for streamablehttp MCP Gateway calls, Memory
namespace conventions (`firm/.../client/.../summary` style), common defect
classes from PLAN.md §0.3 (D1 stub CMK, D2 wrong region model id, D3 missing
SigV4, etc.) with the fix recipe per defect. Triggers on the same patterns
as `aws-agents:agents-deploy` but provides a quicker lookup than fetching
the full plugin skill. Acceptance: skill markdown renders cleanly; manual
review against PLAN.md confirms D1–D9 fixes are all referenced.

## Task 16: Sync orchestrator-kit/ → root install
**depends_on:** [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
**touches:** [`orchestrator.sh`, `.claude/scripts/**`, `.claude/hooks/**`, `.claude/prompts/**`, `.claude/commands/**`, `.claude/docs/**`, `.claude/skills/agentcore-bundle/**`, `.claude/skills/agent-manifest-to-plan/**`]
**auto_merge:** false

Final task: sync the canonical kit (`orchestrator-kit/`) into the running
root install. Run `.claude/scripts/kit-upgrade.sh orchestrator-kit/ --apply`
which atomically copies kit-owned files (orchestrator.sh +
.claude/{scripts,hooks,prompts,commands,docs}/) into the repo root with
shellcheck + `bash -n` validation, reverting on failure. `kit-upgrade.sh`
deliberately excludes `.claude/skills/`, so additionally `cp -rn
orchestrator-kit/.claude/skills/agentcore-bundle .claude/skills/` and the
same for `agent-manifest-to-plan` to bring the new bundled skills into the
live install. Acceptance: `kit-upgrade.sh orchestrator-kit/` (no `--apply`)
reports no drift; the two new skill directories exist under
`.claude/skills/`; `bash -n orchestrator.sh` and shellcheck pass. **Manual
merge required** — this is the one task that flips the running orchestrator
to the new behaviour; final eyes are mandatory.
