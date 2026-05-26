# Plan format

Specification for the markdown format that `ingest-plan.sh` accepts.
Plans that do not match this format are rejected at ingest time with no
partial side effects (no state file, no GitHub issues created).

## File-level structure

A plan is a single markdown file under `.claude/plans/`. The file name
must match `PLAN-<NN>-<slug>.md` where `<NN>` is a zero-padded
two-digit number unique per repo.

The file may optionally begin with a **YAML frontmatter block** —
`---` on line 1, zero or more `key: value` lines, and a closing `---`
on its own line — before the `# Plan title` line. See
[Plan-level frontmatter fields](#plan-level-frontmatter-fields). When
the frontmatter block is absent, the file starts directly with the
`# Plan title` line.

After the title comes optional descriptive prose. Tasks start at
`## Task N:` headers and end at the next `## ` header or end-of-file.

## Required task header fields

Every task has this structure:

```markdown
## Task N: <one-line title>
**depends_on:** [N, M, ...]
**touches:** [`glob1`, `glob2`, ...]

<task body — prose, code blocks, checkbox steps>
```

### `depends_on:` — required

List of task numbers from the same plan that must complete (their
issues closed) before this task is eligible to run. Empty list (`[]`)
means no dependencies — the task is ready immediately at ingest.

Validation:
- All values must reference task numbers that exist in this plan.
- A task may not depend on itself.
- The dependency graph must be acyclic.

### `touches:` — required

List of file globs (gitignore-style syntax) that this task expects to
modify. The parallel scheduler uses this to detect collisions: two
in-flight tasks whose `touches:` globs expand to overlapping concrete
files will not run concurrently.

`touches:` **MUST** be non-empty. An empty list would let the scheduler
treat the task as conflict-free with everything — the precise
silent-failure mode this field exists to prevent. If a task genuinely
modifies nothing (e.g. "review and respond to feedback"), it should
not be in the plan.

Each entry is wrapped in backticks for markdown readability. Examples:
- `` `src/utils/format.py` `` — single file
- `` `src/components/**` `` — recursive directory match
- `` `migrations/*.sql` `` — files matching pattern in one directory

## Plan-level frontmatter fields

Frontmatter is written as a standard YAML block at the very top of the
file: `---` on line 1, key/value lines, and a closing `---` on its own
line, before the `# Plan title` heading. This is the same syntax
`ingest-plan.sh` already uses to read `auto_recommended`. All fields are
optional unless otherwise noted. Unknown keys are **rejected** by
`ingest-plan.sh` with a clear error naming the offending key — silent
acceptance is the precise failure mode this kit has been bitten by
before (see prior incidents involving typo'd field names that silently
no-op'd). Add new keys only after updating this spec and the parser.

```markdown
---
env: staging
aws:
  account: "123456789012"
  region: ap-southeast-2
  profile: deploy-role
  cdk_app_path: infrastructure
requires: [PLAN-03, PLAN-04]
pre_flight:
  issue_title: "PLAN-05 preflight checks"
  checklist:
    - Bedrock model access enabled in ap-southeast-2
    - cdk bootstrap done for account 123456789012
    - AWS_PROFILE set in cron env
auto_recommended: false
---

# PLAN-05-aws-deploy-support — deploy pipeline
```

### `env:` — `dev` | `staging` | `prod`

Target deployment environment for all tasks in this plan. Default: `dev`.

Consumed by `orchestrator.sh` (T12): state file and lock paths are
namespaced per env so that `dev` and `staging` plans can run in parallel
without contending on the same orchestrator lock:

```
.claude/state/<env>/orchestrator.lock/
.claude/state/<env>/cdk-stack-locks/
```

Validation:
- Value must be one of `dev`, `staging`, or `prod` (case-sensitive).
- Plans using `autonomous` deploy mode on any task must not omit this
  field (the env label is embedded in cost-ceiling tags and deploy logs).

### `aws:` — AWS execution context

Plan-level block required whenever any task uses `deploy_mode: autonomous`
or the cdk-diff artifact (T6), deploy-watch phase (T8), or cost ceiling
(T10). All four sub-keys are consumed together; omitting any sub-key when
the block is present is a validation error.

| Sub-key | Type | Description |
|---|---|---|
| `account` | string | 12-digit AWS account ID (quoted to avoid YAML integer truncation) |
| `region` | string | AWS region slug, e.g. `ap-southeast-2` |
| `profile` | string | Named AWS CLI profile to assume |
| `cdk_app_path` | string | Repo-relative path to the CDK app directory, e.g. `infrastructure` |

Consumed by:
- `launch-worker.sh` (T5): exports `AWS_PROFILE`, `AWS_REGION`,
  `AWS_DEFAULT_REGION`, `CDK_DEFAULT_ACCOUNT`, and `CDK_DEFAULT_REGION`
  into the worker environment before `claude -p`.
- `cdk-diff.sh` (T6): `cd $cdk_app_path && cdk diff <stack>`.
- `deploy-watch.sh` (T8): reads account/region to poll CloudFormation.
- `cost-check.sh` (T10): calls `aws ce get-cost-and-usage` scoped to the
  account.

Validation:
- `account` must match `^[0-9]{12}$`.
- `region` must be a non-empty string (format not further validated at
  ingest; deployment failures will surface invalid region names at
  runtime).
- `profile` must be a non-empty string.
- `cdk_app_path` must be a non-empty string; `ingest-plan.sh` does not
  check that the directory exists (the worktree may not be populated at
  ingest time).
- If any task in the plan has `deploy_mode: autonomous`, the `aws:` block
  is required; ingest rejects the plan if the block is absent.

Example:

```yaml
aws:
  account: "123456789012"
  region: us-east-1
  profile: my-deploy-role
  cdk_app_path: infra
```

### `requires:` — inter-plan ordering

Array of plan IDs (`PLAN-NN` format) that must reach `status: done`
before this plan is allowed to run. Consumed by `plan-promote.sh` (T11),
which checks each referenced plan's archived state file before marking
the current plan active.

```yaml
requires: [PLAN-03, PLAN-04]
```

Validation:
- Each entry must match `^PLAN-[0-9]{2}$`.
- Every referenced plan must exist (either archived or active) in
  `.claude/plans/` at the time `plan-promote.sh` runs; if an entry
  references a plan that does not exist at ingest time, `ingest-plan.sh`
  emits a warning but does **not** reject the plan (the referenced plan
  may be created later).
- Self-reference (`requires: [PLAN-05]` inside PLAN-05) is rejected at
  ingest.

### `pre_flight:` — operator gate

Object that configures a mandatory human-review gate before the
orchestrator's first phase runs. Consumed by `preflight-gate.sh` (T4).

| Sub-key | Type | Description |
|---|---|---|
| `issue_title` | string | Title of the GitHub issue that `preflight-gate.sh` creates on first tick |
| `checklist` | string[] | Each entry rendered as a `- [ ]` checkbox line in the issue body |

Behaviour:
1. On the first orchestrator tick after ingest, `preflight-gate.sh` opens
   a GitHub issue with the given `issue_title` and `checklist` rendered as
   unchecked boxes (if the issue does not already exist).
2. All subsequent phases (refresh-deps, launch-pass, etc.) are **skipped**
   until the issue is closed.
3. The issue number is stored in the state file (`pre_flight_issue`) so
   re-ticks can locate it without searching.

Use case: "Bedrock model access enabled", "cdk bootstrap done for the
target account", "AWS_PROFILE is set in cron env". The preflight gate
ensures a human has verified environment readiness before any worker
launches.

Validation:
- `issue_title` must be a non-empty string.
- `checklist` must be a non-empty array of non-empty strings.
- Both sub-keys are required when `pre_flight:` is present; an
  `pre_flight:` block with missing sub-keys is rejected at ingest.

Example:

```yaml
pre_flight:
  issue_title: "PLAN-05 preflight checks"
  checklist:
    - Bedrock model access enabled in ap-southeast-2
    - cdk bootstrap done for account 123456789012
    - AWS_PROFILE set in cron env
```

### `auto_recommended:` — suppress auto-recommendation prompt

Boolean. Default `false`. When `true`, the plan-author skill and
`ingest-plan.sh` suppress the post-ingest prompt that asks the operator
whether to set this plan as the active plan in the orchestrator. Set to
`true` for plans that should be queued rather than immediately activated
(e.g., plans ingested as part of a batch by an upstream automation).

Consumed by `ingest-plan.sh` (written into the state file's
`auto_recommended` key). The orchestrator does not read this flag at
tick time; it is advisory for the ingest UI only.

## Optional task header fields

### `auto_merge: false`

Explicit override of the ingest-time sensitive-pattern detection.
Setting `false` adds this task to `auto_merge_overrides` in the state
file regardless of whether the task body matches the IAM/schema/secrets
pattern list. Use when the auto-detector would miss a task that should
still be human-reviewed.

```markdown
## Task 7: Rename internal cache directory
**depends_on:** []
**touches:** [`src/cache/**`]
**auto_merge:** false
```

Default (field omitted): auto-detector decides based on patterns listed
in `ingest-plan.sh`.

### `max_turns: <int>`

Override the worker's per-task `claude -p --max-turns` cap for this
task only. Used when a task integrates with alpha-tier APIs, large
docs lookups, or other surfaces that legitimately need more turns
than the global default to converge.

```markdown
## Task 7: CDK Agent stack using aws_bedrock_agentcore_alpha
**depends_on:** [6]
**touches:** [`infra/agent_stack/**`]
**max_turns:** 60
```

Precedence: per-task `max_turns:` in the plan beats `$ORCH_MAX_TURNS`
env beats the built-in default of 30. The env var stays useful as a
one-off global override during debugging; plans should set the value
explicitly when a task is reliably tight against the default.

### `acceptance: [...]`

Optional list of acceptance criteria — the machine-checkable definition of
done for this task. Same bracketed, backtick-wrapped list syntax as
`touches:`. Each entry is a short, verifiable statement.

```markdown
## Task 3: Add input validation to the checkout handler
**depends_on:** [2]
**touches:** [`src/checkout/handler.py`, `tests/test_handler.py`]
**acceptance:** [`returns 200 on a valid body`, `rejects an empty body with 400`, `unit tests cover both the valid and invalid paths`]
```

Captured into `tasks.<N>.acceptance` (an array of strings) at ingest. When
present, the criteria are:

- injected into the **worker** prompt as an explicit numbered block; the
  worker must satisfy every item before reporting `status: complete` and
  records each in its `acceptance_check` output.
- injected into the **reviewer** prompt; the reviewer verifies each
  criterion against the diff and emits a `blocker` finding for any it cannot
  confirm — so an unmet criterion blocks the merge gate.

Keep each criterion to a short phrase. Commas inside a criterion are
preserved (each entry is backtick-wrapped), but avoid embedded backticks or
double-quotes. A task with no `acceptance:` line behaves exactly as before —
the field is optional and additive.

Default (field omitted): no structured criteria; "done" is judged from the
task prose by the reviewer as before.

### `deploy_mode: operator | autonomous`

Controls whether the worker runs `cdk deploy` itself or stops short
and hands off to the operator. Default: `operator`.

| Value | Behaviour |
|---|---|
| `operator` | Worker prepares the branch and posts a `cdk diff` artifact as a PR comment (T6). The operator reviews the diff and merges manually. No `cdk deploy` is executed by the worker. |
| `autonomous` | Worker runs `cdk deploy <stack>` after the PR is green. `deploy-watch.sh` (T8) tracks the disowned deployment and updates task status when it finishes or fails. |

The `autonomous` mode requires the plan's `aws:` frontmatter block to
be present (ingest rejects the plan if a task has `deploy_mode:
autonomous` but `aws:` is absent).

`deploy_mode: autonomous` combined with `auto_merge: false` is
permitted: the operator merges the PR by hand once satisfied with the
`cdk diff` artifact, and `deploy-watch.sh` (T8) then begins tracking
the autonomous deploy that the worker launched. This is the intended
pattern for sensitive infrastructure changes that still benefit from
automated deploy monitoring.

```markdown
## Task 9: Deploy authentication stack
**depends_on:** [8]
**touches:** [`infrastructure/stacks/auth_stack.py`]
**deploy_mode:** autonomous
```

Consumed by `launch-worker.sh` (T5): injects the `DEPLOY_MODE` env var
into the worker's environment so the worker prompt can branch on it.
`deploy-watch.sh` (T8) reads `deploy_mode` from the state file to decide
whether to start monitoring CloudFormation after the PR merges.

### `smoke_test: <shell command>`

One-line shell command to execute after the PR merges and CI turns green.
Consumed by `post-merge-check.sh` (T9).

```markdown
## Task 3: Wire receipt-sender into checkout flow
**depends_on:** [2]
**touches:** [`src/checkout/handler.py`]
**smoke_test:** python -m pytest tests/integration/test_checkout.py -k receipt -x
```

Behaviour:
- `post-merge-check.sh` runs the command with the plan's AWS env exported
  (`AWS_PROFILE`, `AWS_REGION`, etc. from the `aws:` block if present).
- Timeout: 5 minutes. Configurable via `ORCH_SMOKE_TIMEOUT_S` env var
  (default `300`).
- Exit 0 → PR labelled `orch:smoke-ok`; downstream dependent tasks proceed
  normally.
- Non-zero exit or timeout → PR labelled `orch:smoke-failed`; all pending
  tasks that `depends_on` this task are cascade-blocked with
  `blocked_reason: smoke_failed_tN`.

The command string is passed to `bash -c` inside the merged worktree,
so relative paths resolve against the repo root. Avoid multi-statement
chains; if the test requires setup, put that logic in a script and
invoke the script here.

Validation:
- Must be a non-empty string on a single line (no embedded newlines).
- `ingest-plan.sh` does not validate that the referenced executable
  exists — runtime failures surface via the `orch:smoke-failed` label.

## Worked example

The example below shows a plan that uses all new fields. Fields whose
defaults are acceptable are omitted.

```markdown
---
env: staging
aws:
  account: "123456789012"
  region: ap-southeast-2
  profile: deploy-role
  cdk_app_path: infrastructure
requires: [PLAN-03]
pre_flight:
  issue_title: "PLAN-05 preflight checks"
  checklist:
    - cdk bootstrap done for account 123456789012 in ap-southeast-2
    - AWS_PROFILE=deploy-role is set in the cron environment
    - Bedrock us.anthropic.claude-sonnet-4-5 access enabled
---

# PLAN-05-aws-deploy-support — CDK deploy pipeline

## Task 1: Add receipt template module
**depends_on:** []
**touches:** [`src/receipts/template.py`]

Add `render_receipt(order: Order) -> str` returning HTML.
Commit: `feat: add receipt template`.

## Task 2: Add receipt-sender Lambda
**depends_on:** [1]
**touches:** [`lambdas/send_receipt/**`, `tests/test_send_receipt.py`]
**smoke_test:** python -m pytest tests/integration/test_send_receipt.py -x

Calls `render_receipt` from task 1 and posts to SES.
Commit: `feat: add receipt-sender Lambda`.

## Task 3: Deploy receipt-sender stack
**depends_on:** [2]
**touches:** [`infrastructure/stacks/receipt_stack.py`]
**deploy_mode:** autonomous
**auto_merge:** false
**smoke_test:** aws lambda invoke --function-name receipt-sender --payload '{}' /tmp/out.json && cat /tmp/out.json

Deploy the receipt-sender Lambda via CDK. Operator must approve the
cdk diff PR comment before the auto-merge gate passes.
Commit: `feat(infra): deploy receipt-sender stack`.
```

> Note: Task 3 uses `auto_merge: false` with `deploy_mode: autonomous`.
> This is the documented combination for sensitive infrastructure
> changes — the operator merges the PR manually, then `deploy-watch.sh`
> (T8) begins tracking the CDK deploy that the worker launched after
> the PR went green.

## Ingest rejections

`ingest-plan.sh` exits non-zero (with a stderr message naming the
offending field) when any of the following hold:

**Task-level:**
- A task has no `**depends_on:**` line
- A task has no `**touches:**` line, or `touches:` is empty
- `depends_on:` references a task number not present in this plan
- A task depends on itself
- The dependency graph contains a cycle
- A task header line uses syntax other than `## Task N: <title>`
- `deploy_mode:` value is not `operator` or `autonomous`
- `smoke_test:` value contains embedded newlines
- A task has `deploy_mode: autonomous` but the plan has no `aws:` block

**Frontmatter-level:**
- `env:` is not one of `dev`, `staging`, `prod`
- `aws:` block is present but missing one or more of `account`,
  `region`, `profile`, `cdk_app_path`
- `aws.account` does not match `^[0-9]{12}$`
- `requires:` contains an entry that does not match `^PLAN-[0-9]{2}$`
- `requires:` contains the current plan's own ID (self-reference)
- `pre_flight:` block is present but `issue_title` or `checklist` is
  missing or empty

Failed validation produces no partial state — fix the plan and re-run.

## Conversion regression test

After changes to `/plan-format` or `plan-author`, exercise the fixtures:

1. Install the kit into a sacrificial test target (e.g.,
   `weclaudecode/claudecode-test-target`).
2. Copy `docs/fixtures/freeform-plan-input.md` into the target's
   `docs/fixtures/`.
3. In a Claude Code session at the test target:
   ```
   /plan-format docs/fixtures/freeform-plan-input.md receipts
   ```
4. Provide `docs/receipts.md` when the gap-fill question asks about
   task 5's `touches`.
5. Confirm `ingest-plan.sh` exits 0 and the resulting state.json has:
   - `total_tasks: 5`
   - `auto_merge_overrides: {"4": false}` (task 4 mentions `infra/`
     and IAM — flagged by the sensitive-pattern detector).
6. Compare the output PLAN file's structure (not byte-for-byte) to
   `docs/fixtures/expected-PLAN-99-freeform.md`.

For the skill, trigger it with "design an orchestrator plan to ..."
and confirm the produced PLAN passes ingest. The shape is necessarily
less deterministic than the converter's, so verify only that ingest
accepts the output.
