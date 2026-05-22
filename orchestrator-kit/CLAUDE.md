# CLAUDE.md

You are working in a project that is sometimes driven by an autonomous
orchestrator loop. Treat every session as if it might be unattended.

## Stack defaults

> Replace this section with your actual stack. Keep it tight — every line is
> token cost on every invocation.

- **Languages:** Python 3.11, TypeScript 5.x, SQL
- **Cloud:** AWS (serverless-first) — Lambda, API Gateway, S3, DynamoDB, RDS, Bedrock
- **IaC:** Terraform for everything except agent infra; CDK Python for AgentCore
- **Frontend:** React + Vite + Tailwind, deployed on Vercel
- **CI/CD:** GitHub Actions
- **Package mgmt:** `uv` for Python, `pnpm` for JS
- **Tests:** pytest, vitest

## Must-rules (do not violate without explicit instruction)

- Never write IAM policies that allow `*:*` or `*` resource on writes
- Never commit secrets, tokens, or `.env` files
- Never `force-push` to `main` or branches with open PRs
- Never delete migration files; supersede them
- Always add tests for new behavior; TDD where the plan specifies it
- Always run the project's lint + test commands before committing

## Conventions

- Conventional commits (feat:, fix:, chore:, refactor:, test:, docs:)
- One logical change per commit; one task per PR
- Branch naming: `claude/plan-<NN>-task-<M>` for orchestrator branches
- File paths in commit messages where useful
- No comments explaining what code does; only why if non-obvious

## When working autonomously

Read these before any tool calls:

1. `.claude/defaults.md` — when-in-doubt rules
2. `.claude/state/decisions.md` — decisions made on prior tasks (consistency matters)

If you would normally ask the user a question, instead apply the decision
policy in `.claude/prompts/worker-superpower.md`. Never block on a question
when running unattended.

## Plan authoring helpers

- `/plan-format <input> [slug]` — converts a freeform plan into a valid
  `.claude/plans/PLAN-NN-<slug>.md` and validates via `ingest-plan.sh`.
- `plan-author` skill — triggers on "design an orchestrator plan for
  X"; walks goal → decomposition → emit + validate.

Both refuse to clobber existing PLAN files and never commit. Format spec:
`.claude/docs/PLAN-FORMAT.md`.

## Skills available

(List any custom skills installed in this repo or globally that the worker
should consider for specific task types.)

- `superpowers:executing-plans` — for plan execution
- `superpowers:subagent-driven-development` — for parallel subtask delegation
