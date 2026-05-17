# claudecode-automation

Source repository for the **Claude Code Plan Orchestrator** — an
autonomous loop that executes superpower-style implementation plans
task-by-task with pre-push review and conditional auto-merge.

## Repository layout

- **`orchestrator-kit/`** — canonical kit. Copy this into a target repo
  to install. See [`orchestrator-kit/README.md`](orchestrator-kit/README.md)
  for setup instructions.
- **`orchestrator-kit/docs/`** — design docs:
  - [`FIX-PLAN.md`](orchestrator-kit/docs/FIX-PLAN.md) — addressed bugs
    from the 2026-05-09 senior code review.
  - [`FIX-PLAN-AUDIT.md`](orchestrator-kit/docs/FIX-PLAN-AUDIT.md) — verification
    that each FIX-PLAN task landed in the current kit code.
  - [`SDLC-EVOLUTION-PLAN.md`](orchestrator-kit/docs/SDLC-EVOLUTION-PLAN.md)
    — proposed evolution to parallel, dependency-aware execution with
    GitHub Issues as the work queue.
  - [`archive/`](orchestrator-kit/docs/archive/) — pre-fix-plan drafts,
    frozen snapshot, do not edit.
- **`CLAUDE.md`** — guidance for Claude Code sessions working in this repo.

## Test target

End-to-end orchestrator testing runs against a separate sacrificial repo:
[`weclaudecode/claudecode-test-target`](https://github.com/weclaudecode/claudecode-test-target).
That repo's README lists a backlog the test plans exercise.
