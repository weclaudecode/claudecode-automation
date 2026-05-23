# Defaults — when in doubt

These rules resolve common decisions without asking. Add to this file as
you discover patterns. The orchestrator's worker reads this on every
invocation.

## Architecture

- **State:** DynamoDB single-table for app data, S3 for blobs, Secrets Manager for secrets
- **Compute:** Lambda first; ECS Fargate only if Lambda timeout/memory insufficient
- **Async:** EventBridge for events, SQS for work queues, Step Functions only when state machine is genuinely needed
- **APIs:** API Gateway REST (not HTTP API) when WAF is needed; HTTP API otherwise

## Code

- **Python:** type hints everywhere, `from __future__ import annotations` at top, dataclasses over TypedDict
- **TypeScript:** strict mode, no `any`, prefer `unknown` then narrow
- **Errors:** raise/throw early, catch at the outermost meaningful boundary, log structured
- **Logging:** stdlib `logging` Python / `pino` Node, JSON format in production
- **Config:** env vars only, validated at startup, no runtime config files

## Tests

- **Unit:** every public function, happy path + at least one failure path
- **Integration:** for anything that crosses a service boundary
- **Mocks:** prefer fakes over mocks; `moto` for AWS, in-process fakes elsewhere
- **Naming:** `test_<unit>_<condition>_<expected>` for Python, `describe/it` for TS

## Dependencies

- Pin to compatible ranges (`^1.2.0` JS, `>=1.2,<2` Python)
- Prefer stdlib where possible; small focused libs over kitchen-sink
- New dependency requires note in decisions.md explaining why

## Naming

- Resources: `<project>-<env>-<purpose>` (lowercase, hyphens)
- Lambdas: verb-noun (`process-order`, `send-receipt`)
- IAM roles: `<service>-<purpose>-role`
- Branches: `claude/plan-<NN>-task-<M>` for orchestrator, `feat/short-name` for human

## Documentation

- README per project root with: setup, run, test, deploy
- ADRs in `docs/adr/NNN-title.md` for any decision affecting multiple components
- API docs auto-generated from code; never hand-written
