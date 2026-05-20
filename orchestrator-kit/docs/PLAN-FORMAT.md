# Plan format

Specification for the markdown format that `ingest-plan.sh` accepts.
Plans that do not match this format are rejected at ingest time with no
partial side effects (no state file, no GitHub issues created).

## File-level structure

A plan is a single markdown file under `.claude/plans/`. The file name
must match `PLAN-<NN>-<slug>.md` where `<NN>` is a zero-padded
two-digit number unique per repo.

The file begins with a `# Plan title` line followed by optional
descriptive prose. Tasks start at `## Task N:` headers and end at the
next `## ` header or end-of-file.

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

## Worked example

```markdown
# PLAN-03-receipts — add receipt sending

## Task 1: Add receipt template module
**depends_on:** []
**touches:** [`src/receipts/template.py`]

Add `render_receipt(order: Order) -> str` returning HTML.
Commit: `feat: add receipt template`.

## Task 2: Add receipt-sender Lambda
**depends_on:** [1]
**touches:** [`lambdas/send_receipt/**`, `tests/test_send_receipt.py`]

Calls `render_receipt` from task 1 and posts to SES.
Commit: `feat: add receipt-sender Lambda`.

## Task 3: Wire receipt-sender into checkout flow
**depends_on:** [2]
**touches:** [`src/checkout/handler.py`]

After successful checkout, invoke the receipt-sender Lambda async.
Commit: `feat: trigger receipt send on checkout`.
```

## Ingest rejections

`ingest-plan.sh` exits non-zero (with a stderr message naming the
offending task) when any of the following hold:

- A task has no `**depends_on:**` line
- A task has no `**touches:**` line, or `touches:` is empty
- `depends_on:` references a task number not present in this plan
- A task depends on itself
- The dependency graph contains a cycle
- A task header line uses syntax other than `## Task N: <title>`

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
