---
name: agent-manifest-to-plan
description: Convert an agent YAML manifest into a draft PLAN-NN orchestrator plan.
argument-hint: <manifest-path>
allowed-tools: Read, Write, Edit, Bash, AskUserQuestion, Glob
---

Read the agent manifest at `$1` and produce a draft `PLAN-NN-<agent-slug>-tools.md`
via the `agent-manifest-to-plan` skill.

## Invocation

```
/agent-manifest-to-plan <manifest-path>
```

`$1` (required): path to the agent YAML manifest file, relative to the repo root
or absolute. The manifest must contain a `tools:` array. Tools with
`status: deferred` are skipped; all others are treated as active.

## What this command does

1. Reads `$1` and extracts: agent name, AWS context (`account`, `region`, `profile`),
   and the list of active tools.
2. Proposes a task decomposition: one shared toolbelt task + one Lambda task per
   active tool + one GatewayStack deploy task.
3. Asks you to confirm (or edit) the decomposition before writing anything.
4. Writes `.claude/plans/PLAN-NN-<agent-slug>-tools.md` in the strict orchestrator
   format.
5. Validates the output with `ingest-plan.sh` and auto-fixes minor issues. Surfaces
   any remaining problems for you to resolve.
6. Refuses to clobber an existing PLAN file.

## Example

```
/agent-manifest-to-plan infrastructure/config/agents/xero_advisor_agent.yaml
```

Produces (for a manifest with 13 active tools):
- `PLAN-NN-xero-advisor-agent-tools.md` with 15 tasks:
  - Task 1: Shared toolbelt module
  - Tasks 2–14: one per active tool
  - Task 15: Re-enable manifest entries + deploy GatewayStack (auto_merge: false)

## Skill reference

Full logic is in `orchestrator-kit/.claude/skills/agent-manifest-to-plan/SKILL.md`.
Invoke the `agent-manifest-to-plan` skill now against `$1`.
