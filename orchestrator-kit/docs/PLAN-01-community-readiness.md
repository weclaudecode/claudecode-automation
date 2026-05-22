# PLAN-01 — open-source community-readiness

Closes the gaps identified in the 2026-05-22 project review (commits
`aeb681b`, `f1f6c10`) so the orchestrator-kit can be published with
basic legitimacy. Plan is authored in the kit's own `PLAN-NN-<slug>.md`
format (dogfood) and passes `ingest-plan.sh` validation, but is
intended for **human execution**, not unattended orchestrator runs —
two items (the visibility flip in the Stage 1 launch checklist and the
asciinema recording in Task 9) need operator action the orchestrator
doesn't support.

## Decisions locked in by the AskUserQuestion pass

- **License:** MIT (operator-supplied copyright holder + year on Task 1).
- **Plan format:** kit's `PLAN-NN-<slug>.md` format, located in
  `orchestrator-kit/docs/` alongside other strategic planning docs
  (`FIX-PLAN.md`, `SDLC-EVOLUTION-PLAN.md`). Not in `.claude/plans/`
  because the orchestrator isn't running this plan.
- **Scope:** Stage 1 (must-haves) + Stage 2 (should-haves). Nice-to-haves
  (CHANGELOG, roadmap, plan-author showcase) deferred.
- **Visibility flip:** happens after Stage 1 lands, before Stage 2
  starts. Stage 2 is post-launch polish.

## Dependency graph

```
   1 ─┐
       ├─→ 3 ─────────────→ (Stage 1 launch)
   2 ─┘                              │
                                     │
   4 ────────────────→ 8             │
                                     │
   5 ──────────────────→ 9 ←─────────┘
                                     │
   6 ────────────────────────────────┤
                                     │
   7 ────────────────────────────────┘
```

Tasks 1, 2, 4, 5, 6, 7 are parallel-safe (disjoint `touches:`). Tasks 3,
8, 9 sequence on their dependencies.

## Sensitive flags

Tasks 4 and 8 modify `.github/workflows/` and will be auto-flagged by
`ingest-plan.sh`'s sensitive-pattern detector. Marked `auto_merge: false`
explicitly for clarity. The remaining tasks are routine.

---

## Stage 1 — must-haves (ends with the public flip)

## Task 1: Add MIT LICENSE at repo root
**depends_on:** []
**touches:** [`LICENSE`]

Drop in the canonical MIT license text. GitHub auto-detects it and
shows the license badge on the repo landing page.

Steps:
1. Create `LICENSE` at repo root with the OSI-approved MIT text from
   <https://opensource.org/license/mit>. Copyright line:
   `Copyright (c) 2026 weclaudecode`. Single file, no badges, no
   subdirectory.
2. Verify GitHub detects it after the next push:
   `gh repo view --json licenseInfo -q .licenseInfo.name` → `"MIT License"`.

Commit: `chore: add MIT LICENSE`

## Task 2: Add SECURITY.md disclosing the bypassPermissions model
**depends_on:** []
**touches:** [`SECURITY.md`]

The kit ships workers with `--permission-mode bypassPermissions` (see
`orchestrator-kit/.claude/scripts/launch-worker.sh:191`), which means
workers can run arbitrary Bash, modify any file, and call any tool
without prompts. First-time readers need this disclosed up front, not
buried in the install section.

Steps:
1. Create `SECURITY.md` at repo root with sections:
   - **What workers can do** — explicit list: file writes anywhere
     under the repo, arbitrary Bash including network calls, git
     operations, `gh` calls under the operator's authenticated token.
   - **Safety layers in the kit** — reviewer phase's `safety_block`
     category for IAM/schema/secrets findings; `auto_merge_overrides`
     for sensitive tasks; iter cap (`review_iter_cap`) for runaway
     workers; mandatory branch protection on `main`.
   - **Recommended deployment posture** — single-tenant repo with
     branch protection enabled; isolated VM or container if the
     operator is paranoid about supply-chain compromise of any
     dependency the worker might install; operator's `gh` token
     scoped to the target repo only, not org-wide.
   - **Reporting vulnerabilities** — email `robbie@weclaudecode.com`
     (do not file public issues for security reports).
2. Keep under 80 lines. This is a "before you install" warning, not a
   comprehensive threat model.

Commit: `docs: add SECURITY.md disclosing bypassPermissions model`

## Task 3: Rewrite root README.md with honest first impressions
**depends_on:** [1, 2]
**touches:** [`README.md`]

The repo-root `README.md` (not `orchestrator-kit/README.md`) is what
GitHub visitors see first. Currently it's a thin pointer; needs to
front-load the prerequisites that disqualify users (so they self-select
fast) and link to LICENSE + SECURITY now that both exist.

Steps:
1. Rewrite the first ~30 lines to lead with:
   - One-sentence elevator pitch (the existing repo description is
     fine — quote it).
   - **Prerequisites box** above the install instructions: Claude Max
     subscription with `claude` CLI authenticated, `gh` CLI
     authenticated, `gawk`/`jq`/`python3`/`git`, optional `gtimeout`
     (`brew install coreutils` on macOS), GitHub repo with `main`
     branch + branch protection allowing auto-merge.
   - **What this is NOT** — interactive coding assistant (use Claude
     Code directly), Devin alternative (different category), drop-in
     CI agent (requires repo-level setup).
   - Link to `SECURITY.md` with a one-liner: "Workers run with
     `--permission-mode bypassPermissions`. Read SECURITY.md before
     installing."
2. Keep links to `orchestrator-kit/README.md` for install + usage
   detail. Don't duplicate that content here.
3. Add a "Status" line near the top: `Status: v0.1 — early; expect
   sharp edges. See PLAN-01-community-readiness.md for the roadmap.`
4. License badge near the top after the LICENSE file lands.
5. Verify with `grep -nE "Max plan|bypassPermissions|gawk" README.md` —
   each term present at least once in the prerequisites region.

Commit: `docs(readme): honest prerequisites + security disclosure + license link`

## Task 4: Add GitHub Actions shellcheck workflow
**depends_on:** []
**touches:** [`.github/workflows/ci.yml`]
**auto_merge:** false

Catches the doc/code drift class that took months to surface in the
review (e.g. `acceptEdits` vs `bypassPermissions` lie in the README).
Single workflow file, extensible by Task 8.

Steps:
1. Create `.github/workflows/ci.yml`:
   - Triggers: `pull_request` to `main`, `push` to `main`.
   - Permissions block (top-level): `contents: read`,
     `pull-requests: read`. No `write` scopes — verification-only.
   - Job `shellcheck` on `ubuntu-latest`:
     - `actions/checkout@v4`
     - Install shellcheck via `sudo apt-get update && sudo apt-get install -y shellcheck`
       (preinstalled on ubuntu-latest, but pin explicitly).
     - Run `shellcheck -S warning $(find orchestrator-kit -type f -name "*.sh")`
       — exits non-zero on warning-level findings. The current tree
       has known pre-existing SC2164 warnings (`cd` without `|| exit`
       in `launch-worker.sh:202,236,280`); either fix those in this
       task (out of scope per format spec) or exclude SC2164 with
       `-e SC2164` in this initial workflow. **Recommend:** start
       with `-e SC2164` so the workflow is green on day one, file a
       follow-up to fix the three callsites and remove the exclusion.
2. Do not add deploy/test/release jobs in this task. Task 8 extends.
3. Verify locally before pushing: `act -j shellcheck` if the operator
   has `act` installed; otherwise inspect the YAML for typos with
   `yamllint .github/workflows/ci.yml`.

Commit: `ci: add shellcheck workflow for orchestrator-kit shell scripts`

## Task 5: Add examples/ directory with one runnable demo plan
**depends_on:** []
**touches:** [`orchestrator-kit/examples/README.md`, `orchestrator-kit/examples/PLAN-01-add-status-section.md`]

A first-time visitor needs to see what a real PLAN looks like end-to-end.
The `docs/fixtures/PLAN-02-cloudtrail-agent.md` is a parser test input,
not a "look how this works" demo. This task adds a tiny one-task plan
that demonstrates the format and the ingest output.

Steps:
1. Create `orchestrator-kit/examples/PLAN-01-add-status-section.md` —
   a minimal one-task plan with realistic content:
   - `## Task 1: Add a Status section to README.md`
   - `**depends_on:** []`
   - `` **touches:** [`README.md`] ``
   - Three steps: read README, insert a `## Status` section under the
     title, commit with `docs: add Status section`.
2. Create `orchestrator-kit/examples/README.md` walking through:
   - Where to put the plan (`.claude/plans/`).
   - How to ingest: `.claude/scripts/ingest-plan.sh
     .claude/plans/PLAN-01-add-status-section.md`.
   - What the resulting state file looks like (paste the exact JSON,
     annotated — no `auto_merge_overrides`, `total_tasks: 1`,
     `status: in_progress`, task 1 with `status: pending`).
   - How to create the GitHub issue: `.claude/scripts/create-issues.sh`.
   - What happens on the first tick: `find-ready-tasks` returns task 1,
     `launch-worker` spawns, PR opens, reviewer runs, auto-merge fires.
   - Expected end state: state file in `.claude/plans/archive/`,
     task 1 `status: merged`.
3. Do **not** commit a pre-generated `.state.json` for the example —
   walking the operator through running `ingest-plan.sh` themselves is
   more honest and proves the install works.
4. Verify the example PLAN passes ingest by copy-running from any
   target repo with the kit installed:
   `bash <kit>/.claude/scripts/ingest-plan.sh
   orchestrator-kit/examples/PLAN-01-add-status-section.md` → exit 0,
   prints "Tasks: 1, Auto-merge disabled: none".

Commit: `docs(examples): add minimal runnable PLAN with walkthrough`

## Stage 1 launch checklist

Operator-run after Tasks 1-5 are merged. Not a tracked plan task
(`gh` commands don't touch any tracked file).

1. Confirm `gh repo view --json licenseInfo,description` returns sane
   values. License should be MIT, description matches the existing one.
2. Flip visibility:
   `gh repo edit --visibility public --accept-visibility-change-consequences`.
3. (Optional) Set repo topics for discoverability:
   `gh repo edit --add-topic claude-code,orchestrator,autonomous-agents,github-automation`.
4. (Optional) Post one announce — Hacker News "Show HN" or the
   Anthropic Discord's `#projects` channel. Lead with the niche
   (Claude Max + multi-task plans + PR-per-task), not generic
   "AI codes for you" framing.
5. Do not enable GitHub Discussions, Wiki, or Projects yet. Add them
   only if engagement materializes — empty surfaces signal "abandoned"
   to first-time visitors.

---

## Stage 2 — should-haves (post-launch)

Start these only after the Stage 1 launch checklist completes and the
repo is public.

## Task 6: Add CONTRIBUTING.md
**depends_on:** []
**touches:** [`CONTRIBUTING.md`]

A contributor opening the first PR needs to know: what style does the
bash follow, what's the testing convention, how do I run shellcheck
locally, what's the bash-3.2-portability constraint about.

Steps:
1. Create `CONTRIBUTING.md` at repo root with sections:
   - **Local setup** — required tools (link back to README prereqs),
     `chmod +x` on scripts after cloning.
   - **Running checks locally** — `shellcheck -S warning $(find
     orchestrator-kit -name "*.sh")`; the integration test from
     Task 8 once it lands.
   - **Bash style** — `set -uo pipefail` at the top of phase scripts
     (NOT `-e` — `refresh-deps.sh` had to be fixed for this); bash
     3.2-compatible (no associative arrays, no `mapfile`, no
     `wait -n`); use `gawk` everywhere (BSD awk silently no-ops
     `match($0, re, array)` — see `orchestrator-kit/.claude/scripts/
     ingest-plan.sh`'s dependency check for prior art).
   - **State-write convention** — all `state.json` writes go through
     `state_write` in `_dispatcher_lib.sh` (not bare `jq … > tmp && mv`)
     so concurrent ticks under `MAX_PARALLEL > 1` don't corrupt state.
   - **Hooks should never block on infrastructure failures** — `exit 0`
     with a stderr note when the network/API is down; `exit 2` only
     for genuine review blockers.
   - **PR conventions** — Conventional Commits (`feat:`, `fix:`,
     `docs:`, `chore:`, `ci:`, `test:`); one logical change per PR;
     reference the offending file + line in PR descriptions.
2. Link from README.md ("How to contribute" line under the Status
   line) once this file exists.

Commit: `docs: add CONTRIBUTING.md with bash style + testing conventions`

## Task 7: Add GitHub issue templates
**depends_on:** []
**touches:** [`.github/ISSUE_TEMPLATE/bug-report.yml`, `.github/ISSUE_TEMPLATE/plan-ingest-failure.yml`, `.github/ISSUE_TEMPLATE/orchestrator-stuck.yml`, `.github/ISSUE_TEMPLATE/config.yml`]

Direct the support load. Three templates cover the realistic failure
modes; `config.yml` disables blank issues so reporters pick one.

Steps:
1. `.github/ISSUE_TEMPLATE/bug-report.yml` — generic bug template
   asking for: kit version (commit SHA), macOS/Linux + version,
   `gawk --version`, `gh --version`, the exact command that failed,
   the contents of `.claude/state/orchestrator.log` (last 50 lines),
   and the relevant state file if any.
2. `.github/ISSUE_TEMPLATE/plan-ingest-failure.yml` — asks for the
   plan file, the exact `ingest-plan.sh` stderr output, and whether
   the operator has `gawk` installed (the most common cause).
3. `.github/ISSUE_TEMPLATE/orchestrator-stuck.yml` — asks for the
   tick log (last 100 lines), `git worktree list`,
   `ls .claude/state/`, the state file showing the stuck task's
   status, and `gh pr list --author @me` to see open PRs.
4. `.github/ISSUE_TEMPLATE/config.yml`:
   ```yaml
   blank_issues_enabled: false
   contact_links:
     - name: Discussion / question
       url: https://github.com/<owner>/<repo>/discussions
       about: Use Discussions for questions, ideas, and show-and-tells.
   ```
   (Only include the `discussions` link once Discussions are enabled
   — drop it from the initial commit if Discussions are still off.)

Commit: `docs: add GitHub issue templates for the three realistic failure modes`

## Task 8: Add integration test exercising fixture plans
**depends_on:** [4]
**touches:** [`.github/workflows/ci.yml`, `orchestrator-kit/tests/README.md`, `orchestrator-kit/tests/test_ingest_fixtures.sh`]
**auto_merge:** false

A real test would invoke `claude -p` against a sandbox repo —
expensive and non-deterministic. This task adds the cheap layer
underneath: assert `ingest-plan.sh` accepts the existing fixtures and
that `find-ready-tasks.sh` returns the expected task numbers from each
ingest's state.json. Catches FSM regressions without spending API
credits.

Steps:
1. Create `orchestrator-kit/tests/test_ingest_fixtures.sh`:
   - `set -uo pipefail`.
   - For each plan in `orchestrator-kit/docs/fixtures/PLAN-*.md`
     (skipping `expected-*.md`):
     - Copy plan + the scripts into a `mktemp -d` scratch dir.
     - Run `ingest-plan.sh` against it; assert exit 0.
     - `jq` the generated state.json for sanity: `total_tasks > 0`,
       `.tasks | type == "object"`, every task has `status: pending`,
       `auto_merge_overrides` is present (object, possibly empty).
   - Specifically for `PLAN-02-cloudtrail-agent.md` (the rich
     fixture): assert `total_tasks == 9` and
     `auto_merge_overrides | keys` includes `"6"` and `"9"` (the
     sensitive-flagged tasks called out in the fixture preamble).
   - Print pass/fail summary; exit non-zero if any fixture fails.
2. Create `orchestrator-kit/tests/README.md` documenting:
   - What `test_ingest_fixtures.sh` covers (and what it doesn't —
     no real `claude -p`, no `gh` calls).
   - How to add a new fixture (drop it in `docs/fixtures/`, update
     the per-fixture assertions if the new plan has sensitive
     flags).
3. Extend `.github/workflows/ci.yml` (created in Task 4) with a
   second job `ingest-fixtures`:
   - Same `permissions: contents: read` only.
   - Install `gawk`, `jq`, `python3`.
   - Run `bash orchestrator-kit/tests/test_ingest_fixtures.sh`.
4. Verify locally: `bash orchestrator-kit/tests/test_ingest_fixtures.sh`
   exits 0 against the current fixtures.

Commit: `test: add ingest-plan fixture regression test + CI job`

## Task 9: Record asciinema demo
**depends_on:** [5]
**touches:** [`orchestrator-kit/docs/demo.cast`, `orchestrator-kit/docs/demo.md`, `README.md`]

A 90-120 second terminal recording showing: install the kit, ingest
the Task 5 example plan, watch a tick run, see the PR open, see it
merge. The single highest-leverage marketing artifact for the niche
this tool targets.

This task is **mostly operator action** (recording a real session is
not something the kit can automate). Code/doc changes are limited to
committing the `.cast` file and adding the link from the README.

Steps:
1. Operator: `brew install asciinema` (or distro equivalent).
2. Operator: clone a sacrificial test target (the existing
   `weclaudecode/claudecode-test-target` is the canonical option;
   create a fresh one if it's already populated).
3. Operator: prepare the demo script — a 2-minute checklist of
   commands matching the Task 5 walkthrough. Practice once
   off-camera; the goal is no hesitation, no typo corrections.
4. Operator: record with `asciinema rec -t "claudecode-automation
   demo" orchestrator-kit/docs/demo.cast`. Aim for 90-120s;
   absolute cap 180s. Trim trailing pauses in post if needed
   (asciinema's `idle-time-limit` flag set to `1.5` at record
   time auto-collapses idle waits).
5. Create `orchestrator-kit/docs/demo.md` with:
   - One-paragraph "What you're about to see".
   - The exact command sequence shown in the cast (for
     accessibility — screen-reader users can't watch the cast).
   - asciinema embed: link to `https://asciinema.org/a/<id>`
     after uploading.
6. Link from root README.md immediately under the prerequisites
   block: `**See it run:** [90-second demo](orchestrator-kit/docs/demo.md)`.

Commit: `docs: add asciinema demo + README link`

