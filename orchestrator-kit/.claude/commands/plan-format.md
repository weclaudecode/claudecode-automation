---
description: Convert a freeform plan markdown into orchestrator PLAN-NN-slug.md format and validate via ingest-plan.sh
argument-hint: <input-path> [slug]
allowed-tools: Read, Write, Edit, Bash, AskUserQuestion, Grep, Glob
---

You are converting a freeform plan markdown file into the orchestrator's strict `PLAN-NN-<slug>.md` format. Your output must pass `.claude/scripts/ingest-plan.sh` validation.

## Inputs

- `$1` (required): path to the input freeform plan markdown file, relative to repo root.
- `$2` (optional): kebab-case slug for the output filename. Inferred if omitted.

## Reference

Read `orchestrator-kit/docs/PLAN-FORMAT.md` (or `docs/PLAN-FORMAT.md` if the kit has been installed into a target repo — same content) for the canonical format spec. Do this first.

## Workflow

### 1. Environment checks (abort-and-stop conditions)

- If `.claude/plans/` does not exist: abort with `"orchestrator kit not installed in this repo — see orchestrator-kit/README.md"`.
- If `$1` does not exist as a file: abort.
- If `$1` is already inside `.claude/plans/`: abort with `"input and output would collide. Copy to a draft path first."`.

### 2. Pick `NN`

Run: `ls .claude/plans/PLAN-*.md 2>/dev/null | sed 's/.*PLAN-\([0-9]*\).*/\1/' | sort -n | tail -1`

- Parse as integer. Increment. Zero-pad to 2 digits → `NN`.
- If result is empty, start at `01`.
- If result would exceed 99, abort with `"plan numbering at 99 — use 3-digit numbering or archive old plans first."`

### 3. Pick slug

In order, until one succeeds:
1. If `$2` was supplied: validate it matches `^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$` (kebab, 1-40 chars). If invalid, abort with the regex shown.
2. Strip leading `PLAN-NN-` from `basename "$1" .md`. If non-empty and matches the regex, use it.
3. Slugify the input file's H1 (`# ...`): lowercase, replace non-alphanumeric with `-`, collapse runs of `-`, trim leading/trailing `-`, cap at 40 chars.
4. If all three failed, ask via `AskUserQuestion`: `"What slug should the output file use? (kebab-case, 1-40 chars)"`.

### 4. Refuse-to-clobber check

If `.claude/plans/PLAN-NN-<slug>.md` already exists, abort: `"target file exists — delete it first or pick a different slug."`. Same for `.claude/plans/PLAN-NN-<slug>.state.json`.

### 5. Parse input

Read `$1`. Identify task sections. Tasks may appear as:
- `## Task N:` headers
- `### N.` or `## N.` numbered headers
- Numbered list items (`1.`, `2.`)
- Bulleted lines starting with `- Task N` or similar

Extract a title (one-line summary) and a body (everything until the next task boundary) for each.

### 6. Infer per-task fields

For each task, classify each field as **confident** or **low-confidence**:

**`depends_on:`**
- Confident if the body explicitly references another task's output by number ("after task 2", "depends on N", "uses output from task M", or a function name introduced by a prior task).
- Confident `[]` if the task is clearly first or has no inter-task dependency cues.
- Low-confidence otherwise.

**`touches:`**
- Confident if the body explicitly names file paths (`src/foo.py`, `infra/bar.tf`) or unambiguous globs (`lambdas/send_receipt/**`).
- Low-confidence if files are vague ("update docs", "tests for the above") or absent.

### 7. Preserve user-supplied lines

If the input already contains `**depends_on:**` or `**touches:**` lines within a task body, preserve them verbatim. Only fill missing fields.

### 8. Do NOT pre-emit `auto_merge: false`

`ingest-plan.sh:227-289` already auto-flags tasks matching IAM / migration / secrets patterns. Do not add `**auto_merge:** false` lines based on your own heuristics — that would double-tag. Only preserve `auto_merge:` lines the user supplied explicitly in the input.

### 9. Emit the draft

Write `.claude/plans/PLAN-NN-<slug>.md` with this shape:

```markdown
# PLAN-NN-<slug> — <title from input H1 or slug>

[optional: 1-paragraph prose from input intro, preserved]

## Task 1: <title>
**depends_on:** [...]
**touches:** [...]

<body — preserved from input, lightly cleaned>

## Task 2: <title>
...
```

### 10. Validate with bounded retry

```
attempts = 0
loop while attempts < 3:
  run: .claude/scripts/ingest-plan.sh .claude/plans/PLAN-NN-<slug>.md
  capture exit code and stderr.
  if exit 0:
    print state.json summary line by line, exit success.
  parse stderr lines (format: "task N: <kind>" or "cycle: A -> B -> A").
  classify each error:
    auto-fixable:
      - "depends_on includes itself" → drop the self-ref
      - "depends_on references nonexistent task N" → if N looks like an off-by-one (e.g. task 6 in a 5-task plan referencing 6), drop it; else mark needs-user-input
      - malformed touches glob (unclosed backtick, etc.) → patch syntax
    needs-user-input:
      - "**touches:** must be present and non-empty"
      - "cycle: ..."
      - any "depends_on references nonexistent task N" where N has no obvious off-by-one fix
  if any auto-fixable applied:
    patch the file in place, attempts++, continue loop.
  else:
    break.

if pending needs-user-input list is non-empty:
  emit ONE AskUserQuestion containing all pending items.
  Example phrasing: "ingest-plan.sh rejected the draft. For tasks 5 and 7, **touches:** is missing — what files do they modify? For task 3, depends_on references nonexistent task 99 — should this be dropped or renumbered?"
  apply user's answers to the file.
  run ingest-plan.sh once more.
  if exit 0: print summary, success.
  else: print raw stderr verbatim, exit failure. Do NOT loop further.
```

### 11. Output on success

Print:
- The output path (`.claude/plans/PLAN-NN-<slug>.md`)
- The state.json `total_tasks` count
- The `auto_merge_overrides` keys
- Next-step hint: `"review the state file, then run .claude/scripts/create-issues.sh on it when ready."`

## Hard rules

- Do NOT commit. The user commits.
- Do NOT create GitHub issues. That's `create-issues.sh`'s job.
- Do NOT clobber existing PLAN files. Refuse instead.
- Do NOT modify `ingest-plan.sh` or any other kit script.
- Cap total work: 3 auto-fix attempts + 1 gap-fill = at most 4 ingest runs. Then surface raw stderr.
