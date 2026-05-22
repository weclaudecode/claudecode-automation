# Examples

Minimal example plans and a first-run walkthrough for operators who have
just installed the kit into a target repo and want to confirm it's wired
up correctly end-to-end before authoring real plans.

## Prerequisites

Install the kit into a target repo and complete the auth/branch-protection
setup described in [`../README.md`](../README.md). This walkthrough assumes
you're sitting in the target repo with the kit already in place.

## Walkthrough: `PLAN-01-add-status-section.md`

A one-task plan that adds a `## Status` section to your target repo's
`README.md`. Small enough to run end-to-end in a few minutes; large enough
to exercise ingest → issue → worker → reviewer → PR → auto-merge.

**1. Copy the example into your kit-installed repo:**

```bash
cp <path-to-claudecode-automation>/orchestrator-kit/examples/PLAN-01-add-status-section.md .claude/plans/
```

**2. Run ingest:**

```bash
.claude/scripts/ingest-plan.sh .claude/plans/PLAN-01-add-status-section.md
```

Expected output line: `Tasks: 1, Auto-merge disabled: none, Auto-recommended: false`.

**3. Inspect the generated state file:**

```bash
cat .claude/plans/PLAN-01-add-status-section.state.json | jq .
```

Top-level fields (see v2 schema section of [`../README.md`](../README.md)
for the full spec — not duplicated here):

- `.plan_file` — relative path to the source PLAN markdown.
- `.total_tasks` — task count; should be `1` for this example.
- `.status` — overall plan status (`in_progress` | `blocked` | `done`).
- `.tasks["1"]` — per-task record: `title`, `depends_on`, `touches`,
  `issue`, `pr`, `status` (`pending` here until the worker runs),
  `retries`.
- `.auto_merge_overrides` — task-number → `false` map; empty here because
  the task doesn't touch sensitive paths.
- `.auto_recommended` — `false` because the plan didn't request
  cross-the-board auto-merge.
- `.ingested_at` — UTC timestamp of ingest.

**4. Create the GitHub issue for the task:**

```bash
.claude/scripts/create-issues.sh .claude/plans/PLAN-01-add-status-section.state.json
```

This populates `.tasks["1"].issue` with the new issue number.

**5. Run one orchestrator tick:**

```bash
./orchestrator.sh
```

**6. What you should see:**

- A `claude/plan-01-task-1` branch and worktree.
- A PR opened against `main` with the `## Status` section diff.
- The reviewer phase posting a PR comment (or skipping cleanly if the
  diff is trivial).
- Auto-merge enabled on the PR (`gh pr merge --auto`) and `pending_pr`
  recorded in the state file.

**7. After the PR merges and the next tick runs:**

- `.tasks["1"].status` flips to `merged`.
- `.status` becomes `done`.
- The state file is moved to `.claude/plans/archive/`.

## What this example doesn't show

- **Sensitive-flagged tasks** — paths under `iam/`, migrations, secrets
  trigger `auto_merge_overrides` and require manual merge.
- **Multi-task dependency graphs** — `depends_on` with real edges,
  topological scheduling, parallel workers via the `*-pass.sh` scripts.
- **Iteration on reviewer blockers** — worker re-running after the
  reviewer posts blocking comments.

For a plan that exercises all of the above, see
[`../docs/fixtures/PLAN-02-cloudtrail-agent.md`](../docs/fixtures/PLAN-02-cloudtrail-agent.md).
