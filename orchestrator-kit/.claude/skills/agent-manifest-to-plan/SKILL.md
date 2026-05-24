---
name: agent-manifest-to-plan
description: Use when the user wants to convert an agent YAML manifest into a draft PLAN-NN orchestrator plan. Triggers on phrases like "convert agent manifest to plan", "create plan from manifest", "generate plan from manifest", "manifest to plan", "/agent-manifest-to-plan <path>". Reads tools[] from the manifest and emits tasks: one shared toolbelt task + one Lambda-implementation task per active tool + one GatewayStack deploy task. Output passes ingest-plan.sh without manual edits.
allowed-tools: Read, Write, Edit, Bash, AskUserQuestion, Glob
---

You are generating a new orchestrator plan from an agent YAML manifest. Your output is a
`.claude/plans/PLAN-NN-<slug>.md` file that `ingest-plan.sh` will accept without manual edits.

## Reference

Read the canonical format spec from one of these paths (first that exists):
- `orchestrator-kit/docs/PLAN-FORMAT.md` (kit source repo)
- `.claude/docs/PLAN-FORMAT.md`
- `docs/PLAN-FORMAT.md`

If none exist, use the format rules embedded below.

## Environment checks

- If `.claude/plans/` does not exist: abort with `"orchestrator kit not installed in this repo — see orchestrator-kit/README.md"`.
- If the manifest path does not exist: abort with `"manifest file not found: <path>"`.

## Phase 1 — Read and parse the manifest

Read the YAML file at the given path. Extract:

| Field | YAML path | Notes |
|---|---|---|
| `agent_name` | `name` or `agent` (whichever is present) | Used for slug and directory names |
| `region` | `model.region` or top-level `region` | Optional; use `ap-southeast-2` as default |
| `account` | top-level `account` | Optional; 12-digit string |
| `profile` | top-level `profile` | Optional; use `deploy-role` as default |
| `model_id` | `model.model_id` or top-level `model_id` | Informational only |
| `tools` | `tools[]` | Array of tool entries |

For each tool entry, extract:
- `id` or `name` — the tool identifier (with dashes)
- `status` — optional; skip entries where `status: deferred` (or `status: disabled`)
- `description` — optional; used in task body
- `auth` — optional; informational for task body (`iam`, `oauth_3lo`, etc.)

Active tools are those with no `status` field, or `status: active`.

If `tools` is empty or all tools are deferred: abort with `"no active tools found in manifest — nothing to generate a plan for."`.

## Phase 2 — Confirm decomposition

Compute:
- `N_active` = count of active tools
- `N_total_tasks` = 1 (toolbelt) + N_active (per-tool Lambda tasks) + 1 (re-enable manifest + deploy GatewayStack)

Present a summary to the user via `AskUserQuestion`:

```
Manifest: <agent_name>
Active tools (<N_active>):
  1. <tool-id>
  2. <tool-id>
  ...
Deferred (skipped): <tool-id>, <tool-id>

Generated plan structure:
  Task 1: Shared toolbelt module   [depends_on: []]
  Task 2: Tool <tool1> — Lambda + schema   [depends_on: [1]]
  Task 3: Tool <tool2> — Lambda + schema   [depends_on: [1]]
  ...
  Task <N>: Re-enable tools in manifest + deploy GatewayStack   [depends_on: [2, 3, ..., N-1]]

Total tasks: <N_total_tasks>
Plan file will be: .claude/plans/PLAN-NN-<agent-slug>-tools.md

Proceed? [Yes] / [Edit task structure] / [Abort]
```

If the user chooses `Edit task structure`, ask them to paste corrections and apply. If `Abort`, stop.

## Phase 3 — Pick NN and slug

**Pick NN:**
Run: `ls .claude/plans/PLAN-*.md 2>/dev/null | sed 's/.*PLAN-\([0-9]*\).*/\1/' | sort -n | tail -1`
- Parse as integer. Increment. Zero-pad to 2 digits → `NN`.
- If result is empty, start at `01`.
- If result would exceed 99: abort with `"plan numbering at 99 — archive old plans first."`.

**Pick slug:**
- Slugify `<agent_name>-tools`: lowercase, replace non-alphanumeric with `-`, collapse runs of `-`, trim leading/trailing `-`, cap at 40 chars.
- Example: `xero-advisor-agent` → `xero-advisor-agent-tools`.

**Refuse-to-clobber:**
- If `.claude/plans/PLAN-NN-<slug>.md` already exists: abort with `"target file exists — delete it first or pick a different slug."`.
- Same check for `.claude/plans/PLAN-NN-<slug>.state.json`.

## Phase 4 — Generate the plan file

Write `.claude/plans/PLAN-NN-<slug>.md` with the following structure.

### Frontmatter

Always emit an `env: dev` block. Include `aws:` block if account and region are available from the manifest:

```markdown
---
env: dev
aws:
  account: "<account>"
  region: <region>
  profile: <profile>
  cdk_app_path: infrastructure
---
```

If account is not in the manifest, omit the `aws:` block entirely (do not emit with placeholder values).

### Title and intro

```markdown
# PLAN-NN-<slug> — implement <N_active> agent tools for <agent_name>

This plan implements the <N_active> active Lambda tools declared in the
`<agent_name>` manifest, plus the shared toolbelt module they depend on.
Each tool gets its own Lambda function and Gateway target. The final task
re-enables deferred-skipped entries in the manifest and deploys the
GatewayStack.

Reference architecture: agents/<agent_name>/tools/<tool_name>/index.py
+ schema.json + requirements.txt per tool; shared helpers at
agents/<agent_name>/tools/_shared/.
```

### Task 1: Shared toolbelt module

```markdown
## Task 1: Shared toolbelt module
**depends_on:** []
**touches:** [`agents/<agent_name>/tools/_shared/**`]

Create the shared toolbelt at `agents/<agent_name>/tools/_shared/`:
- `xero_client.py` — `XeroClient(firm_id, accountant_id)` wrapping token
  resolution, retry/backoff, and connection pooling.
- `gateway_context.py` — `parse_context(event) -> Context` extracting
  `firm_id`, `accountant_id`, `session_id` from the MCP event envelope.
- `supabase.py` — `audit_start`, `audit_finish`, `persist_snapshot` helpers.
- `normalise.py` — one normaliser function per Xero report type.
- `errors.py` — `ToolError`, `XeroUpstreamError`, and related exceptions.

Each tool task depends on this module. Write unit tests in
`agents/<agent_name>/tools/_shared/test_shared.py` using `pytest`.
Commit: `feat: add <agent_name> shared toolbelt module`.
```

### Per-tool tasks (one per active tool, tasks 2..N_active+1)

For tool number `i` (1-indexed), task number = `i + 1`:

```markdown
## Task <i+1>: Tool <tool-id> — Lambda + schema
**depends_on:** [1]
**touches:** [`agents/<agent_name>/tools/<tool_name_underscored>/**`]

Implement the `<tool-id>` tool Lambda at
`agents/<agent_name>/tools/<tool_name_underscored>/`:
- `index.py` — handler using the shared toolbelt. ~30 lines: parse params →
  call XeroClient (or Supabase for IAM-auth tools) → normalise → audit → return.
- `schema.json` — MCP tool schema with `name`, `description`, `inputSchema`.
- `requirements.txt` — tool-specific dependencies (if any beyond shared).
- `test_handler.py` — unit test stubbing Xero/Supabase responses with fixtures,
  asserting the normalised output shape.

<Tool description from manifest if present>
Auth: <auth value from manifest, or "iam" if not specified>

Commit: `feat: implement <tool-id> Lambda tool`.
```

**Directory name convention:** convert `tool-id` (dashes) to `tool_name` (underscores) for the filesystem path. Example: `get-profit-and-loss` → `get_profit_and_loss`.

### Final task: re-enable manifest + deploy GatewayStack

Task number = `N_active + 2`.
`depends_on` = all per-tool task numbers: `[2, 3, ..., N_active + 1]`.

```markdown
## Task <N_active+2>: Re-enable tools in manifest and deploy GatewayStack
**depends_on:** [2, 3, ..., <N_active+1>]
**touches:** [`infrastructure/config/agents/**`, `infrastructure/stacks/**`]
**auto_merge:** false

1. Remove any `status: deferred` lines from the manifest
   `infrastructure/config/agents/<manifest_filename>` so all <N_active>
   tools are active.
2. Run `python scripts/validate_manifests.py` — must exit 0.
3. Deploy: `cd infrastructure && cdk deploy GatewayStack-<agent_name>`.
4. Verify via AWS CLI:
   - `aws lambda list-functions --region <region>` → <N_active> functions
     with prefix `<agent_name>-tool-`.
   - `aws bedrock-agentcore-control list-gateway-targets --gateway-identifier <gw-id>`
     → <N_active> targets.

Commit: `feat(infra): deploy <agent_name> GatewayStack with all <N_active> tools`.
```

This task is marked `auto_merge: false` because it includes a CDK deploy touching IAM and infrastructure.

## Phase 5 — Validate with bounded retry

```
attempts = 0
loop while attempts < 3:
  run: .claude/scripts/ingest-plan.sh .claude/plans/PLAN-NN-<slug>.md
  capture exit code and stderr.
  if exit 0: print summary, exit success.
  parse stderr lines (format: "task N: <kind>" or "cycle: A -> B -> A").
  classify each error:
    auto-fixable:
      - "depends_on includes itself" → drop the self-ref
      - "depends_on references nonexistent task N" → if off-by-one, drop; else mark needs-user-input
      - malformed touches glob → patch syntax
    needs-user-input:
      - "**touches:** must be present and non-empty"
      - "cycle: ..."
      - any unresolvable depends_on reference
  if any auto-fixable applied:
    patch the file in place, attempts++, continue loop.
  else:
    break.

if pending needs-user-input list is non-empty:
  emit ONE AskUserQuestion with all pending items.
  apply user's answers.
  run ingest-plan.sh once more.
  if exit 0: print summary, success.
  else: print raw stderr verbatim, exit failure.
```

## Output on success

Print:
- The output path (`.claude/plans/PLAN-NN-<slug>.md`)
- Task count and which tasks have `auto_merge_overrides` set
- The active tools list
- Next-step hint: `"review the plan file, then run .claude/scripts/create-issues.sh on it when ready."`

## Hard rules

- Do NOT commit. The user commits.
- Do NOT create GitHub issues. That's `create-issues.sh`'s job.
- Do NOT clobber existing PLAN files. Refuse instead.
- Do NOT modify `ingest-plan.sh` or any kit scripts.
- Do NOT pre-emit `auto_merge: false` on per-tool tasks — only on the final deploy task (which is genuinely infra-sensitive). Trust the sensitive-pattern detector for everything else.
- The final GatewayStack deploy task always gets `auto_merge: false` because it touches infrastructure stacks.
- Cap total work: 3 auto-fix attempts + 1 gap-fill = at most 4 ingest runs.
- Skip deferred tools silently; note in the intro paragraph how many were skipped.
- The `aws:` frontmatter block requires all four sub-keys (`account`, `region`, `profile`, `cdk_app_path`). If `account` is missing from the manifest, omit the `aws:` block entirely rather than emitting an incomplete one.
