---
name: plan-author
description: Use when the user wants to design a new implementation plan for the Claude Code orchestrator (PLAN-NN-slug.md). Triggers on phrases like "design an orchestrator plan", "plan for the orchestrator to run", "create an orchestrator plan for X", or "draft a PLAN-NN file". Walks user through goal → decomposition → dep/touches → emit + validate via ingest-plan.sh.
---

You are interactively designing a new orchestrator plan with the user. Your output is a `.claude/plans/PLAN-NN-<slug>.md` file that `ingest-plan.sh` will accept.

## Reference

Read `orchestrator-kit/docs/PLAN-FORMAT.md` (or `docs/PLAN-FORMAT.md` in a target repo) for the canonical format spec. Do this first.

## Environment checks

- If `.claude/plans/` does not exist: abort with `"orchestrator kit not installed in this repo — see orchestrator-kit/README.md"`.

## Phases

### Phase 1 — Brainstorm (≤2 questions)

Emit one `AskUserQuestion` block with up to 2 questions:

1. **Goal:** "In 1-3 sentences, what's the goal of this plan?" — open-ended, but provide 2-3 short example phrasings if useful (e.g., "Add receipt-sending to checkout", "Migrate auth from JWT to session cookies"). Also confirm: "Which repo will run this plan?" (default: current working dir).

2. **Shape:** "Roughly how many tasks?" with options like 3, 5, 7-8, or "let me list them" (the user types their own task titles).

### Phase 2 — Decompose

Based on the user's goal and task count:
- Propose 3-8 task titles (or use the user's list verbatim if they provided one).
- Present as a numbered markdown list.
- Ask via `AskUserQuestion`: "Does this decomposition look right?" with options: `Yes, proceed` / `Edit titles` / `Different decomposition` / `Different task count`.

If `Edit titles`: ask the user to paste the revised list inline. Apply edits.
If `Different decomposition` or `Different task count`: re-propose once, then ask again. If still not approved, ask the user to provide titles directly.

### Phase 3 — Detail

For each task, infer `depends_on` and `touches`:

**`depends_on`:** based on the natural ordering and any user hints from Phase 1-2 (e.g., "Task 3 uses Task 1's output" → `depends_on: [1]`). Confident if the user named the dependency. Low-confidence otherwise.

**`touches`:** based on the goal and task titles. Confident if the title or user input names files/modules unambiguously. Low-confidence if vague.

Collect all low-confidence fields into a pending list.

If pending list is non-empty, emit ONE `AskUserQuestion`:
- Phrasing: "I need a few details before writing the plan: for task N, which files will it modify? For task M, does it depend on task K?"
- Group questions by task for clarity.

Apply user's answers.

### Phase 4 — Emit + validate

1. **Pick NN:** glob `.claude/plans/PLAN-*.md`, take max integer, increment, zero-pad to 2. Start at `01` if none. Refuse beyond 99.

2. **Pick slug:** slugify the user's goal (lowercase, kebab, ≤40 chars). If unable, ask via `AskUserQuestion`.

3. **Refuse-to-clobber:** if `.claude/plans/PLAN-NN-<slug>.md` exists, abort with the path and ask for a different slug.

4. **Write the file** to `.claude/plans/PLAN-NN-<slug>.md` with the format:

```markdown
# PLAN-NN-<slug> — <plan title from goal>

<1-paragraph summary from user's goal>

## Task 1: <title>
**depends_on:** [...]
**touches:** [...]

<task body — 1-3 sentences from the decomposition discussion>

## Task 2: <title>
...
```

5. **Validate with bounded retry:**

```
attempts = 0
loop while attempts < 3:
  run: .claude/scripts/ingest-plan.sh .claude/plans/PLAN-NN-<slug>.md
  capture exit code and stderr.
  if exit 0:
    print summary, success.
  parse stderr lines (format: "task N: <kind>" or "cycle: A -> B -> A").
  classify each error:
    auto-fixable:
      - "depends_on includes itself" → drop the self-ref
      - "depends_on references nonexistent task N" → if N looks
        like an off-by-one (e.g. task 6 in a 5-task plan referencing 6),
        drop it; else mark needs-user-input
      - malformed touches glob (unclosed backtick, etc.) → patch syntax
    needs-user-input:
      - "**touches:** must be present and non-empty"
      - "cycle: ..."
      - any "depends_on references nonexistent task N" with no
        obvious off-by-one fix
  if any auto-fixable applied:
    patch the file in place, attempts++, continue loop.
  else:
    break.

if pending needs-user-input list is non-empty:
  emit ONE AskUserQuestion with all pending items batched.
  apply user's answers to the file.
  run ingest-plan.sh once more.
  if exit 0: print summary, success.
  else: print raw stderr verbatim, exit failure.
```

## Hard rules

- Do NOT pre-emit `**auto_merge:** false`. Trust `ingest-plan.sh`'s sensitive-pattern detector. Only add it if the user explicitly asks for it.
- Do NOT commit. The user commits.
- Do NOT create GitHub issues. That's `create-issues.sh`'s job.
- Do NOT clobber existing PLAN files.
- Cap total work: 3 auto-fix attempts + 1 gap-fill = at most 4 ingest runs.

## Output on success

Print:
- The output path
- Task count + auto_merge_overrides keys
- Next-step hint: `"review the state file, then run .claude/scripts/create-issues.sh on it when ready."`
