# claudecode-automation

**Status: v0.1 — early; expect sharp edges.** See [PLAN-01-community-readiness](orchestrator-kit/docs/PLAN-01-community-readiness.md) for the roadmap.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Autonomous Claude Code orchestrator that executes superpower-style implementation plans task-by-task with pre-push review and conditional auto-merge.

## Prerequisites

Before installing, you need:

- **Claude Max subscription** with `claude` CLI authenticated (`claude /login`). Workers run via `claude -p` and burn Max-plan quota per task. Without Max, the per-task cost is prohibitive.
- **`gh` CLI authenticated** (`gh auth login`) with a token scoped to the target repo. The kit opens PRs, manages labels, and reads PR review state via `gh`.
- **`gawk`, `jq`, `python3`, `git`** — non-optional. `gawk` (not BSD awk) is specifically required because the plan parser uses `match($0, regex, array)` which BSD awk silently no-ops. `brew install gawk jq` on macOS.
- **`gtimeout` (recommended)** — `brew install coreutils` on macOS. Without it, runaway workers can't be timeboxed.
- **GitHub repo with `main` branch and branch protection** allowing auto-merge. The kit's safety model depends on branch protection blocking direct pushes to main.
- **macOS or Linux.** Windows is unsupported.

## Security

> Workers run with `--permission-mode bypassPermissions` — they can run arbitrary Bash, modify any file, and call any tool your `gh` token can reach. **Read [SECURITY.md](SECURITY.md) before installing.**

## What this is NOT

- An interactive coding assistant — use Claude Code directly for that.
- A Devin alternative — Devin is a hosted SaaS agent platform with a GUI. This is a Bash kit that runs in your terminal and on your GitHub repo, against your own Max plan.
- A drop-in CI agent — installation requires repo-level setup (branch protection, labels, `.claude/` directory, optionally cron). The orchestrator runs on its own schedule, not on PRs.

## Installation and usage

See [`orchestrator-kit/README.md`](orchestrator-kit/README.md) for install instructions, the v2 state schema, and per-tick architecture. The plan-authoring helpers (`/plan-format` slash command + `plan-author` skill) are documented there too.

A minimal runnable example is in [`orchestrator-kit/examples/`](orchestrator-kit/examples/) — start there if you want to see the kit run end-to-end before reading the architecture docs.

## License

[MIT](LICENSE). Copyright (c) 2026 weclaudecode.
