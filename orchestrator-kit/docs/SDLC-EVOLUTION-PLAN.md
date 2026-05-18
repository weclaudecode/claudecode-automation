# Orchestrator Kit — SDLC Evolution Plan

Turns the current single-task sequential loop into a parallel, dependency-aware
SDLC where plan ingestion produces GitHub Issues, multiple workers run
concurrently against file-disjoint tasks, and a PR-comment reviewer drives
review-iteration loops to auto-merge.

Sequenced by dependency, not value. Each phase ships independently; nothing
after Phase 1 works until the plan-syntax + Issues foundation is in place.

> **Do NOT enable parallel mode in production until Phase 4 smoke-tests pass on
> a plan with at least one file-overlap collision and one dependency-blocked
> task.** The collision detector is the safety net replacing the existing
> `pending_pr` gate, and it must be exercised before being trusted.

## Decisions baked in (don't relitigate without explicit go-ahead)

| Decision | Choice | Why |
|---|---|---|
| Dependency source | Author-authored in plan (`depends_on:`, `touches:`) | Highest fidelity; LLM-derived deps had silent-failure risk |
| Mid-task question policy | `ORCH_AUTO_RECOMMENDED` env var, default OFF | Opt-in; preserves current Tier-3 halt safety on upgrade |
| Safety net for auto-decided IAM/schema/security | Reviewer hard-block category | Worker-side Tier-3 is bypassed when auto-recommended is ON; reviewer becomes the gate |
| Task queue canonical source | GitHub Issues (per task) + `.state.json` (per plan) | Issues are the work queue; state.json is the plan-level ledger pointing into Issues |
| Parallelism cap | `MAX_PARALLEL=2` default, configurable | Conservative start; raise after observing collision rate |

---

## Phase 0 — Preconditions & smoke harness (no orchestrator changes)

Goal: prove the target repo can actually accept this design, and have a
regression fixture before any code lands.

### Task 0.1 — Branch-protection preflight script

**File:** `orchestrator-kit/.claude/scripts/check-preconditions.sh` (new)

Adds a one-shot script that an operator runs once per target repo before
enabling auto-merge in parallel mode. Fails loudly if branch protection isn't
configured to require CI checks.

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
PROT=$(gh api "repos/$REPO/branches/main/protection" 2>/dev/null || echo "")

[ -z "$PROT" ] && { echo "FAIL: main has no branch protection"; exit 1; }

CHECKS=$(echo "$PROT" | jq -r '.required_status_checks.contexts // [] | length')
[ "$CHECKS" -eq 0 ] && { echo "FAIL: no required status checks on main"; exit 1; }

REVIEWS=$(echo "$PROT" | jq -r '.required_pull_request_reviews // null')
[ "$REVIEWS" = "null" ] && echo "WARN: no required reviews; auto-merge will merge unreviewed PRs"

echo "OK: $CHECKS required check(s); auto-merge eligible"
```

**Verification:** run against a repo with and without protection; confirm
exit codes 0 and 1 respectively.

### Task 0.2 — Repo label seed script

**File:** `orchestrator-kit/.claude/scripts/setup-labels.sh` (new)

Creates the labels the scheduler queries. Idempotent — uses `gh label create
--force`.

Labels to create:
- `orch:plan-NN` (created dynamically per plan; this script just sets the color)
- `orch:task` — marks any orchestrator-managed issue
- `orch:deps-met` — task has no open `depends_on:` issues
- `orch:in-progress` — task picked up by a tick, worker spawned
- `orch:review-blocked` — reviewer posted blocker comments; awaiting worker iteration
- `orch:safety-block` — reviewer found hard-block class (IAM/schema/security); needs human
- `orch:needs-robbie` — sensitive-flagged at ingest; auto-merge disabled
- `agent-followup` — opened by worker for out-of-scope findings (existing)

**Verification:** run twice in a row; second run is a no-op.

### Task 0.3 — Smoke-test plan fixture

**File:** `orchestrator-kit/docs/fixtures/PLAN-SMOKE.md` (new)

A 4-task plan exercising every scheduler edge case: deps chain, file overlap,
sensitive-flag, and a parallelizable pair. Used by Phase 1 and Phase 4
verification.

```markdown
# PLAN-SMOKE — exercises scheduler edge cases

## Task 1: Add util module
**depends_on:** []
**touches:** [`src/utils/format.ts`]

Add a `formatBytes(n: number)` helper.

## Task 2: Use util in component A
**depends_on:** [1]
**touches:** [`src/components/A.tsx`]

Import formatBytes; render a size.

## Task 3: Use util in component B (parallel with 2)
**depends_on:** [1]
**touches:** [`src/components/B.tsx`]

Import formatBytes; render a size.

## Task 4: Add IAM role (must NOT auto-merge)
**depends_on:** []
**touches:** [`infra/iam.tf`]

Add `aws_iam_role.formatter_writer`.
```

**Verification:** after Phase 1, `ingest-plan.sh` on this file should produce
4 issues; task 4 should carry `orch:needs-robbie`; tasks 2 and 3 should NOT
carry `orch:deps-met` (task 1 still open); task 1 SHOULD carry it.

---

## Phase 1 — Plan syntax, ingest, Issues

Goal: plan markdown is the contract; ingestion produces a GitHub Issues task
list and a per-plan state.json ledger.

### Task 1.1 — Plan markdown syntax extension

**File:** `orchestrator-kit/docs/PLAN-FORMAT.md` (new)

Documents the required and optional task-header fields. Becomes the
authoring spec.

Required per task:
- `## Task N: <title>` — existing
- `**depends_on:** [N, M, ...]` — list of task numbers from same plan. `[]` = no deps.
- `**touches:** [\`glob1\`, \`glob2\`, ...]` — file globs (gitignore syntax). At least one entry required.

Optional:
- `**auto_merge:** false` — explicit override of sensitive-pattern auto-detection
- `**model:** opus` — opt task into stronger model

**Validation rules** (enforced at ingest):
- `touches:` MUST be present and non-empty. Empty `touches:` would let the
  scheduler treat the task as conflict-free with everything, which is the
  exact silent-failure mode we're avoiding.
- All numbers in `depends_on:` must reference real tasks in the same plan.
- No cycles in the dep graph.

### Task 1.2 — Extend `ingest-plan.sh` parser

**File:** `orchestrator-kit/.claude/scripts/ingest-plan.sh:42-49,86-156`

Add a gawk pass that, for each `## Task N:` header, extracts the following
2-4 lines for `**depends_on:**` and `**touches:**` and emits per-task JSON:

```json
{"task": 3, "title": "Use util in B", "depends_on": [1], "touches": ["src/components/B.tsx"]}
```

Reject ingest with non-zero exit + stderr message if any task is missing
`touches:`, references an unknown task in `depends_on:`, or the graph has a
cycle. Cycle detection: build adjacency list, run DFS, error on back-edge.

Write the per-task structures into the existing state file under a new key:

```json
{
  "plan_file": "...",
  "total_tasks": 4,
  "status": "in_progress",
  "tasks": {
    "1": {"depends_on": [], "touches": ["src/utils/format.ts"], "issue": null, "pr": null, "status": "pending"},
    "2": {"depends_on": [1], "touches": ["src/components/A.tsx"], ...},
    ...
  },
  "auto_merge_overrides": {"4": false}
}
```

The legacy `current_task` and `retries_for_current` fields go away. State per
task moves into `tasks.N.status` (`pending` | `in_progress` | `in_review` |
`merged` | `blocked`) and `tasks.N.retries`.

**Verification:** run ingest against `PLAN-SMOKE.md`; confirm state file has
4 task entries, task 4 has `auto_merge_overrides[4] = false`, and a plan with
`depends_on: [99]` is rejected.

### Task 1.3 — Issue creation script

**File:** `orchestrator-kit/.claude/scripts/create-issues.sh` (new)

After ingest, this script reads the state.json and creates one GitHub issue
per task. Each issue:

- Title: `[plan-NN/tM] <task title>`
- Body: the verbatim `## Task M:` section from the plan, plus a footer with
  `depends_on:` issue links (resolved after all issues are created in two
  passes — first create, then edit bodies to insert `#123` links).
- Labels: `orch:task`, `orch:plan-NN`, plus `orch:deps-met` iff `depends_on: []`,
  plus `orch:needs-robbie` iff in `auto_merge_overrides`.

Writes the issue number back into `state.tasks.N.issue`. Idempotent on
re-run: if `state.tasks.N.issue` is already set, skip creation.

**Verification:** run against `PLAN-SMOKE.md`; confirm 4 issues created,
issue 1 has `orch:deps-met`, issue 4 has `orch:needs-robbie`, issues 2 and 3
do NOT have `orch:deps-met`.

### Task 1.4 — Dep-met label refresher

**File:** `orchestrator-kit/.claude/scripts/refresh-deps.sh` (new)

Run at the start of every orchestrator tick. For each open `orch:task`
issue without `orch:deps-met`, check whether all of its `depends_on:` issues
are closed; if so, add `orch:deps-met`.

Reads dependency map from state.json (not from issue body — body parsing is
fragile and the state file is the source of structured truth).

**Verification:** close issue 1 from smoke test manually; run script;
confirm issues 2 and 3 gain `orch:deps-met`.

---

## Phase 2 — PR-comment reviewer

Goal: replace the in-process Stop-hook reviewer with a post-push GitHub PR
review that can drive multi-round iteration.

The Stop hook stays in place but becomes a fast smoke check (lint/format,
no LLM call). The heavy reviewer moves to a separate tick mode.

### Task 2.1 — Strip the Stop hook to a smoke check

**File:** `orchestrator-kit/.claude/hooks/stop-pre-push-review.sh`

Remove the `claude -p` reviewer invocation. Replace with: run `git diff` for
sanity, exit 0. The hook's job is reduced to "stop is allowed" — review
happens after push.

Diff (gist):
```diff
-RESPONSE=$(SKIP_REVIEW=1 claude -p "$(cat "$REVIEW_PROMPT_FILE") ...")
-PASS=$(...)
-if [ "$PASS" = "true" ]; then exit 0; fi
-cat >&2 <<EOF
-PRE-PUSH REVIEWER BLOCKED
-...
-EOF
-exit 2
+# Phase 2: review moved to post-push tick. Stop hook is now a no-op
+# beyond ensuring the worker actually produced a diff.
+[ -z "$(git diff origin/main...HEAD 2>/dev/null)" ] && {
+  echo "stop hook: no diff vs origin/main — worker produced nothing" >&2
+  exit 2
+}
+exit 0
```

**Verification:** smoke test plan completes Task 1; Stop hook no longer
calls `claude -p`; worker's `RUN_OUT` shows fewer turns than pre-Phase-2.

### Task 2.2 — `review-pr.sh` script

**File:** `orchestrator-kit/.claude/scripts/review-pr.sh` (new)

Takes a PR number. Runs the reviewer in a fresh `claude -p` with a hardcoded
read-only tool surface — the reviewer is universally read-only and this
restriction is fixed, not configurable per plan/task/repo. A reviewer that
can `Write`, `git push`, or `gh pr merge` isn't a reviewer.

```bash
claude -p "$REVIEWER_PROMPT_AND_DIFF" \
  --output-format json \
  --model sonnet \
  --disallowed-tools "Edit,Write,NotebookEdit,Bash(git push:*),Bash(gh pr merge:*),Bash(gh pr close:*),Bash(gh pr edit:*),Bash(rm:*)"
```

Deny-list (not allow-list) because the reviewer must be free to read context
beyond the diff: `Read`, `Grep`, `Glob`, and arbitrary `Bash` for `git diff`,
`git log`, `gh api` lookups, and test discovery. The security property we
care about is "no mutation"; the deny list expresses that directly without
constraining gather-context tools we haven't thought of.

Parses the JSON output and posts findings as PR comments:

- Each `blocker` finding → `gh pr review --request-changes` with the issue
  text, line-anchored via `gh api repos/.../pulls/.../comments` for inline.
- Each `safety_block` finding → also adds `orch:safety-block` label.
- If all findings are `nit` or none → `gh pr review --approve`.

Records review iteration count in a hidden HTML comment in the PR body
(`<!-- orch:review-iter:N -->`) so the iteration tick can read it back.

**Verification:** create a test PR with an obvious bug; run script; confirm
review-changes comments are posted; confirm clean PR gets approved. Also
verify the reviewer can't mutate state: inspect the run output JSON
(`--output-format json` includes a tool-call log) and confirm zero entries
match `Edit`, `Write`, or any of the denied `Bash(...)` forms.

### Task 2.3 — New tick modes: `review` and `iterate`

**File:** `orchestrator-kit/orchestrator.sh:1-end` (significant refactor)

> **Sub-plan:** [`DISPATCHER-PLAN.md`](DISPATCHER-PLAN.md) breaks this task into 7 sub-tasks (A-G) with the state machine, lock model, and rollout sequence detailed.

The tick becomes a priority queue dispatcher. Order per tick:

1. **Refresh deps:** `refresh-deps.sh`
2. **Check pending auto-merges:** for each PR in `state.tasks.*.pr` with
   `orch:in-progress`, check `gh pr view --json state`; on MERGED, mark
   task `merged` + close issue; on CLOSED unmerged, mark `blocked`.
3. **Review pass:** for each open PR with new commits since last review
   (compare HEAD sha to `<!-- orch:review-iter -->` recorded sha), run
   `review-pr.sh`.
4. **Iterate pass:** for each PR with `orch:review-blocked` label AND a
   review-changes comment NEWER than the last worker commit, spawn a
   worker in that PR's worktree with prompt "address review comments on
   PR #N". Iteration cap = 3; on hit, label `orch:safety-block` + notify.
5. **Launch pass:** find up to `MAX_PARALLEL - in_progress_count` ready
   tasks via `find-ready-tasks.sh` (Phase 4); launch them.

The lock model changes from one global lockdir to: one **launch lock**
(only one tick may add new workers at a time) plus per-task worktree dirs
that act as natural locks.

**Verification:** create two PRs by hand (one needing review, one needing
iteration); run a tick; confirm both get serviced in one tick.

### Task 2.4 — Iteration cap

**File:** `orchestrator-kit/.claude/scripts/review-pr.sh`

When recording the iteration count, if `N >= ORCH_REVIEW_MAX_ITERS` (default
3), add `orch:safety-block` label, notify, and stop iterating. The PR stays
open for human review.

**Verification:** create a PR; iterate 3 times with a finding that the
worker can't fix (e.g., reviewer asks for a behavior the test forbids);
confirm safety-block label appears on iteration 4 attempt.

---

## Phase 3 — Optional auto-recommended + reviewer hard-blocks

Goal: let workers self-resolve mid-task questions when explicitly opted in,
with the reviewer enforcing the safety floor.

### Task 3.1 — `ORCH_AUTO_RECOMMENDED` toggle

**File:** `orchestrator-kit/orchestrator.sh`, `orchestrator-kit/.claude/prompts/worker-superpower.md`

Add env var `ORCH_AUTO_RECOMMENDED` (default `0`). When `1`, the worker
prompt is augmented with an "auto-resolve policy" section that overrides
the existing Tier 1/2/3:

```diff
+## When ORCH_AUTO_RECOMMENDED is enabled (you'll be told below)
+
+You are in auto-resolve mode. When any tool, skill, or sub-process presents
+a choice with a recommended option (e.g. AskUserQuestion options where the
+first option is marked "(Recommended)", or skill prompts that indicate a
+default), pick the recommended option without escalating. Log every such
+choice to .claude/state/decisions.md with **Severity: routine**.
+
+If the choice has no clearly recommended option, pick the option you would
+most defensibly choose given the plan and CLAUDE.md context, and log with
+**Severity: sensitive**. Do NOT exit non-zero. The PR reviewer is the
+safety gate for any decision that would have been Tier-3 in interactive mode.
```

Pass the flag value into the worker prompt at spawn time via a literal
`AUTO_RECOMMENDED=<0|1>` line so the worker can branch.

**Verification:** with `ORCH_AUTO_RECOMMENDED=1`, run a task that would
trigger a brainstorming-style decision; confirm worker completes (doesn't
exit non-zero) and decisions.md gets an entry. With `=0`, same task
escalates to `blocked`.

### Task 3.2 — Decisions log severity field

**File:** `orchestrator-kit/.claude/prompts/worker-superpower.md:38-44`

Add `Severity` to the decisions.md entry format:

```diff
 ## YYYY-MM-DD HH:MM — Plan NN Task M
 **Decision:** <one line>
+**Severity:** routine | sensitive
+**Recommended option:** yes | no | n/a
 **Reason:** <one line>
 **Reversible:** yes | no
```

Severity rule: `sensitive` iff the touched file path or decision content
matches the sensitive patterns from `ingest-plan.sh:60-85` (IAM, KMS,
schema, migrations, github/workflows, etc.). Routine otherwise.

This gives the operator a single grep for post-hoc audit:
`grep -A2 '\*\*Severity:\*\* sensitive' .claude/state/decisions.md`.

**Verification:** trigger one routine and one sensitive decision; confirm
both fields appear.

### Task 3.3 — Reviewer hard-block category

**File:** `orchestrator-kit/.claude/prompts/reviewer-system.md:42-53`

Add a new severity tier ABOVE `blocker`:

```diff
+## Safety-block findings (HIGHEST severity)
+
+These ALWAYS produce `pass: false` with a `safety_block` severity in the
+JSON output. The worker MUST NOT iterate on these. They require human
+review (the orchestrator will label the PR `orch:safety-block` and stop).
+
+- New IAM permissions/policies, role trust changes, AssumeRole additions
+- Schema or migration changes (any file under `migrations/` or matching
+  `[Aa]lter [Tt]able`, `[Dd]rop [Cc]olumn`, `schema.sql`)
+- Secrets or credentials appearing in the diff (api keys, tokens, .env)
+- CORS broadened, input validation removed, network ACL widened to 0.0.0.0/0
+- New external dependency that calls home (telemetry/analytics SDKs)
+- Changes to .github/workflows/ that alter trigger conditions or permissions
+
 ## Blocker findings
+
+These force pass: false but the worker MAY iterate to address them.
```

Update the JSON schema in the same file to include `"safety_block"` as a
valid `severity` enum value.

**Verification:** craft a diff that adds an IAM statement; run reviewer;
confirm output includes `severity: "safety_block"` and the PR ends up with
the `orch:safety-block` label after Task 2.2 processes it.

### Task 3.4 — Per-plan auto-recommended override

**File:** `orchestrator-kit/.claude/scripts/ingest-plan.sh`

Optional plan-level frontmatter:

```markdown
---
auto_recommended: true
---
# PLAN-04-...
```

Parsed at ingest into `state.auto_recommended` (default false). At tick
time, this value overrides the env var. Lets the operator enable
auto-recommend for a single experimental plan without flipping the global.

**Verification:** ingest two plans, one with frontmatter, one without;
confirm `state.auto_recommended` reflects each.

---

## Phase 4 — Parallel scheduler

Goal: launch up to N tasks in parallel per tick, respecting deps AND file
overlaps.

### Task 4.1 — `find-ready-tasks.sh`

**File:** `orchestrator-kit/.claude/scripts/find-ready-tasks.sh` (new)

Input: state.json path, `MAX_PARALLEL`.
Output: newline-separated list of task numbers safe to launch.

Algorithm:
1. Compute `IN_PROGRESS = {N | state.tasks.N.status in {in_progress, in_review}}`.
2. Compute `IN_PROGRESS_TOUCHES = union(state.tasks.N.touches for N in IN_PROGRESS)`.
3. For each task `T` with `status == pending` and label `orch:deps-met`:
   - If `intersect(T.touches, IN_PROGRESS_TOUCHES)` is non-empty, skip
     (file collision with in-flight work).
   - Else, add to candidate list.
4. Emit candidates until `len(IN_PROGRESS) + emitted == MAX_PARALLEL`.

Glob intersection: expand both sides against the worktree's file list at
tick time; intersect the resulting concrete paths. Two `touches:` entries
collide iff their expanded path sets share any file.

**Verification:** state with task A (touches `src/a/**`) in_progress and
task B pending (touches `src/a/file.ts`): script returns empty. Same A
in_progress, task C pending (touches `src/b/**`): script returns C.

### Task 4.2 — Multi-worker launch in tick

**File:** `orchestrator-kit/orchestrator.sh` (launch pass from Task 2.3)

Replace single-worker logic with a loop bounded by
`MAX_PARALLEL=${ORCH_MAX_PARALLEL:-2}`:

```bash
READY=$(find-ready-tasks.sh "$STATE_FILE" "$MAX_PARALLEL")
for TASK_NUM in $READY; do
  launch_worker "$TASK_NUM" &
  WORKER_PIDS+=($!)
done
wait "${WORKER_PIDS[@]}"
```

Each `launch_worker` is the per-task block extracted into a function:
worktree create, prompt assembly, `claude -p` spawn, exit-code handling,
push, PR open, state.tasks.N.status update.

Worktree path becomes `../wt-planNN-tM-rR` (already in current code) but
multiple can exist concurrently.

**Verification:** smoke plan with tasks 2 and 3 (both deps-met after 1
merges, disjoint touches) launches both in one tick; both PRs open.

### Task 4.3 — Per-task retry independent of plan status

**File:** `orchestrator-kit/orchestrator.sh`

Today, 3 failures on one task blocks the whole plan. With parallel
execution, one task's failure shouldn't halt others. Change:

```diff
-if [ "$NEW_RETRIES" -ge 3 ]; then
-  jq '.status = "blocked"' ...
+if [ "$NEW_RETRIES" -ge 3 ]; then
+  jq --arg t "$TASK_NUM" '.tasks[$t].status = "blocked"' ...
   bash "$NOTIFY" ...
```

Plan-level `status` only flips to `blocked` if ALL non-merged tasks are
`blocked` (i.e., no forward progress possible).

**Verification:** smoke plan where task 2 is forced to fail 3 times; task
3 still progresses to merged; plan stays `in_progress`.

### Task 4.4 — Merge-conflict handling

**File:** `orchestrator-kit/.claude/scripts/rebase-pr.sh` (new), invoked
from the review pass

When `gh pr view --json mergeable -q .mergeable` returns `CONFLICTING`,
the orchestrator:
1. Fetches origin/main into the worktree
2. Runs `git rebase origin/main`
3. If clean: force-push, restart review
4. If conflict: label `orch:safety-block`, notify, leave worktree for
   human

The `touches:` collision detection should prevent most of these, but it
can't prevent semantic conflicts (two tasks edit different files but one
relies on the other's removed API).

**Verification:** stage a merge conflict by hand; confirm script attempts
rebase; if conflict remains, confirm safety-block label.

---

## Phase 5 — Operator UX & post-merge guardrails (follow-ups, not blocking)

### Task 5.1 — Plan dashboard via Issues

**File:** `orchestrator-kit/.claude/scripts/plan-status.sh` (new)

Generates a markdown summary of plan progress by querying issues. Posts
or updates a single pinned issue per plan (`[plan-NN] status`) listing
all task issues, their status, dep graph as a mermaid diagram, current
in-flight PRs. Refreshed at the end of every tick.

### Task 5.2 — Post-merge CI watch

**File:** `orchestrator-kit/.claude/scripts/post-merge-check.sh` (new)

After auto-merge, watch the next N CI runs on main. If main goes red,
notify with the breaking commit (the just-merged PR) and a suggested
revert command. Doesn't auto-revert (too easy to cascade).

### Task 5.3 — Cross-plan collision detection (stretch)

Extend `find-ready-tasks.sh` to consider in-progress tasks across all
active plans, not just within one. Risk: requires global state.json
discovery and locking across plan files. Defer until multi-plan parallel
is a real need.

### Task 5.4 — CI-status gate in review-pass (finding from PLAN-02 smoke)

**File:** `orchestrator-kit/.claude/scripts/review-pass.sh`

Surfaced during the PLAN-02 end-to-end run: the LLM reviewer judges
code-vs-spec but does not proactively check `gh pr checks <PR>`. A PR
whose diff matches the task spec but whose CI is red gets `APPROVE`d,
auto-merge waits forever for a green check that never comes, and the
orchestrator's iterate loop never engages because no `orch:review-blocked`
label is applied.

Fix: before calling `review-pr.sh` in the per-PR loop, fetch the PR's
status checks via `gh pr view --json statusCheckRollup`. If any required
check has `conclusion == "failure"`:

1. Skip the LLM reviewer entirely (cheap short-circuit).
2. Post a synthetic `**Orchestrator review**` COMMENT with a body like:
   ```
   **Orchestrator review** (CI gate, sha `<short_sha>`)

   CI is red — the following checks failed:
   - `<check_name>`: <conclusion> (<run_url>)

   Worker must address before this PR can merge.
   ```
3. Apply `orch:review-blocked` label so iterate-pass picks it up next tick.
4. Skip incrementing the review-iteration counter (CI failures are
   independent of LLM review iterations).

Edge cases to handle:
- `mergeable == CONFLICTING` already routes to `rebase-pr.sh` earlier in
  the loop — that path takes precedence over CI-gate.
- Check status `IN_PROGRESS` or `QUEUED` → defer the LLM review until next
  tick; don't act on incomplete CI.
- No required checks configured → behave as today (run LLM reviewer).

**Verification:** craft a PR where the diff matches its task spec exactly
but a CI step is forced to fail (e.g. `exit 1` in the test job); confirm
review-pass posts the synthetic blocker, applies the label, and that
iterate-pass spawns iterate-pr on the next tick.

### Task 5.5 — Bot identity separation (related to 5.4)

When the orchestrator's gh user equals the PR author, GitHub blocks
`APPROVE`/`REQUEST_CHANGES` reviews. Current fallback in `review-pr.sh`
posts as `COMMENTED` and relies on labels (`orch:review-blocked`,
`orch:safety-block`) to drive downstream behavior. This works but loses
GitHub's formal review-state tracking — repos that enforce required
approvers via branch protection still won't auto-merge.

Document the recommended deployment: separate gh tokens for the worker
identity (write) and the reviewer identity (read + post-review only).
For ops who can't easily run two identities, the COMMENT + label fallback
is the supported path; mention it explicitly in the README's permissions
section.

No code change required; this is a docs + recommended-config task.

### Task 5.6 — Handle PRs that are MERGEABLE but BEHIND main (finding from PLAN-02 smoke)

**File:** `orchestrator-kit/.claude/scripts/rebase-pr.sh`, `review-pass.sh`

Surfaced during the PLAN-02 end-to-end run: when sibling PR B merges
into main while PR A is still in flight, A's `mergeable` stays
`MERGEABLE` but `mergeStateStatus` flips to `BEHIND`. Branch protection
with `required_status_checks.strict: true` (the recommended setting per
`check-preconditions.sh`) blocks the auto-merge until A's branch is
brought up to date with main. The orchestrator's existing rebase logic
only fires on `CONFLICTING`, so BEHIND PRs sit forever — the deadlock
seen during PLAN-02 ticks 9-N.

Fix:
1. In `rebase-pr.sh`, also fetch `mergeStateStatus` and treat `BEHIND`
   as a rebase trigger alongside `CONFLICTING`. Same rebase + force-push
   machinery — BEHIND should never produce conflicts (by definition the
   merge is conflict-free), but use `git rebase --abort` + safety-block
   path as a defensive fallback if it somehow does.
2. In `review-pass.sh`, broaden the per-PR check from
   `mergeable == CONFLICTING` to `(mergeable == CONFLICTING ||
   mergeStateStatus == BEHIND)` so the dispatch fires.

This task ALSO needs a bump to `ORCH_REVIEW_MAX_ITERS` (default 3 → 5)
because the loop seen during PLAN-02 (LLM-blocker → iterate → CI-block
→ iterate → LLM-blocker on the lazy-init pattern) consumed iterations
faster than the cap allowed. Real production work routinely needs 4-5
cycles when the LLM reviewer and CI gate both flag issues.

**Verification:** create two PRs (A, B) from main with no file overlap;
merge B first; confirm PR A immediately transitions to `BEHIND`;
confirm next orchestrator tick invokes `rebase-pr.sh` on A; confirm A's
branch is force-pushed with the rebase and auto-merge fires once CI
re-passes on the new SHA.

---

## Rollout sequence

1. **Phase 0** — ship in any order; non-breaking.
2. **Phase 1** — ship as one unit; ingestion now requires new fields, so
   existing plans need to be updated before re-ingest. Old state.json
   format is incompatible — provide a migration helper script.
3. **Phase 2** — ship as one unit; Stop hook change is breaking for
   in-flight workers, so drain the queue first (`status: blocked` on all
   active plans, ship, re-enable).
4. **Phase 3** — ship as one unit. Defaults preserve current behavior.
5. **Phase 4** — ship behind `ORCH_MAX_PARALLEL` defaulting to 1 (i.e.,
   functionally sequential at first). Raise to 2 after one week of
   sequential-with-new-scheduler operation.
6. **Phase 5** — opportunistic.

## Non-goals

- **Cross-plan dependency graphs.** A task in plan A cannot depend on a
  task in plan B. If needed, merge them into one plan.
- **Dynamic plan editing.** A plan's task graph is frozen at ingest. To
  add tasks, write a new plan.
- **Auto-revert on red main.** Notify only; humans decide.
- **Replacing GitHub Issues with a custom UI.** Issues + labels are
  enough for the operator dashboard.

## Open questions

- **How does the reviewer agent handle PRs from non-orchestrator authors?**
  Default: skip any PR without the `orch:task` label. Confirm before
  Phase 2 ship.
- **What's the right default for `ORCH_MAX_PARALLEL` after Phase 4
  bakes?** Probably 3-4 for repos with disjoint task surfaces, 2 for
  monorepos with shared config files. Measure collision rate from Phase
  4's first month and decide.
- **Should `auto_recommended` decisions in `sensitive` paths halt
  regardless of the toggle?** Strong argument for yes — the toggle is
  about decision questions, not about touching sensitive code. Likely
  Phase 3 follow-up.
