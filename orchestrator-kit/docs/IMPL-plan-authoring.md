# Plan Authoring Tooling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two entry points (`/plan-format` slash command + `plan-author` skill) to the orchestrator-kit that produce valid `.claude/plans/PLAN-NN-<slug>.md` files, validated via `ingest-plan.sh`.

**Architecture:** Two markdown artifacts under `orchestrator-kit/.claude/commands/` and `orchestrator-kit/.claude/skills/`. Both read `docs/PLAN-FORMAT.md` for rules, shell out to `.claude/scripts/ingest-plan.sh` for validation, and use the same write → validate → ≤3 auto-fix → 1 gap-fill loop. No new shell scripts. No changes to `ingest-plan.sh`.

**Tech Stack:** Bash, jq, gawk, markdown. Claude Code skill/command file format (YAML frontmatter + prose body).

**Spec:** [`SPEC-plan-authoring.md`](SPEC-plan-authoring.md). **Format reference:** [`PLAN-FORMAT.md`](PLAN-FORMAT.md).

**Smoke-test target:** `weclaudecode/claudecode-test-target` cloned at `/Users/rb/Documents/Github/claudecode-test-target` (per repo CLAUDE.md). Tasks 5 and 7 install the kit there and exercise the artifacts end-to-end.

---

## File map (changes summary)

```
orchestrator-kit/
  .claude/
    commands/
      plan-format.md                       # CREATE (Task 3)
    skills/
      plan-author/
        SKILL.md                           # CREATE (Task 6)
  docs/
    fixtures/
      freeform-plan-input.md               # CREATE (Task 2)
      expected-PLAN-99-freeform.md         # CREATE (Task 2)
    PLAN-FORMAT.md                         # MODIFY — add "Conversion regression test" (Task 8)
  README.md                                # MODIFY — pointer + (conditional) installer step (Task 9)
```

---

## Task 1: Verify project-level skill loading

**Goal:** Determine whether Claude Code loads skills from `<repo>/.claude/skills/<name>/SKILL.md` automatically when a session opens in that repo, or whether they must live in `~/.claude/skills/`. This affects whether the kit's installer needs to add a copy/symlink step.

**Files:**
- Read: `~/.claude/skills/` (list existing skill structure for reference)
- Read: any Claude Code docs available locally about skill loading
- Create: short note in `orchestrator-kit/docs/SPEC-plan-authoring.md` under "Open implementation questions" → "Resolution"

- [ ] **Step 1: Inspect a known-working skill's structure**

Run:
```bash
ls -la ~/.claude/skills/skill-creator/
cat ~/.claude/skills/skill-creator/SKILL.md | head -10
```
Expected: directory contains a `SKILL.md` (or `skill.md`) with YAML frontmatter starting `---` and a `name:` field matching the directory name.

- [ ] **Step 2: Check whether project-level skills are documented**

Search for any local Claude Code docs (e.g., `~/.claude/CLAUDE.md`, plugin docs) mentioning project-level skill loading:
```bash
grep -ri "project.*skill\|\\.claude/skills" ~/.claude/ 2>/dev/null | head -20
grep -ri "project.*skill\|\\.claude/skills" /Users/rb/Documents/Github/claudecode-automation/orchestrator-kit/ 2>/dev/null | head -20
```

If nothing definitive, fall back to empirical test (Step 3).

- [ ] **Step 3: Empirical test in a scratch repo**

```bash
mkdir -p /tmp/skill-loading-test/.claude/skills/test-loader
cat > /tmp/skill-loading-test/.claude/skills/test-loader/SKILL.md <<'EOF'
---
name: test-loader
description: A throwaway skill used once to confirm Claude Code loads project-level skills from .claude/skills/. Triggers on the literal phrase "ping test-loader".
---

If you see this skill listed in your available skills, the test passed.
EOF
cd /tmp/skill-loading-test
echo "Open this directory in a new Claude Code session and check whether 'test-loader' appears in the available-skills list."
```

The actual confirmation requires running Claude Code in this directory and inspecting the available-skills system reminder. Document the outcome in Step 4.

- [ ] **Step 4: Record the finding**

Edit `orchestrator-kit/docs/SPEC-plan-authoring.md`. At the end of the "Open implementation questions" section, append:

```markdown
### Resolution (Task 1 of IMPL-plan-authoring)

**Project-level skill loading:** [YES — loaded automatically from `<repo>/.claude/skills/`]  OR  [NO — install step required].

Verification method: [docs reference / empirical test in /tmp/skill-loading-test on 2026-05-19].

Implication for installer: [none / add `cp -r orchestrator-kit/.claude/skills/* <repo>/.claude/skills/` to README's "Install into a repo" steps].
```

Pick the variant that matches reality. Clean up `/tmp/skill-loading-test`.

- [ ] **Step 5: Commit**

```bash
cd /Users/rb/Documents/Github/claudecode-automation
git add orchestrator-kit/docs/SPEC-plan-authoring.md
git commit -m "docs(spec): resolve project-level skill loading question"
```

---

## Task 2: Add fixtures (input + expected output)

**Goal:** Create the two fixture files the converter and its regression test will use. These are the "tests" for the prompt-based artifacts.

**Files:**
- Create: `orchestrator-kit/docs/fixtures/freeform-plan-input.md`
- Create: `orchestrator-kit/docs/fixtures/expected-PLAN-99-freeform.md`

- [ ] **Step 1: Create the freeform input fixture**

Write to `orchestrator-kit/docs/fixtures/freeform-plan-input.md`:

````markdown
# Freeform plan — receipts feature

A deliberately rough plan used as a regression fixture for `/plan-format`.
Mixes prose, partial structure, and missing fields by design.

Tasks (rough):

1. Add a receipt template module. Should expose `render_receipt(order)`
   returning HTML. Lives in `src/receipts/template.py`.

2. Add the receipt-sender Lambda. Uses the template from task 1.
   Files: `lambdas/send_receipt/handler.py` + tests under
   `tests/test_send_receipt.py`.

3. Wire the sender into checkout. Modifies `src/checkout/handler.py`.
   Depends on task 2 being merged.

4. Add an IAM role for the Lambda. Files in `infra/iam.tf`.
   This one should NOT auto-merge.

5. Update docs. (No specific files yet — TBD by author.)
````

Save. This input has:
- 5 tasks with varying levels of detail
- Tasks 1, 2, 3, 4 have explicit file paths (confident `touches`)
- Task 5 has no files (low-confidence — should trigger gap-fill)
- Task 3 explicitly states dep on task 2 (confident)
- Tasks 1, 2 have no explicit deps (confident: `[]`)
- Task 4 should trigger sensitive-pattern auto-flag (mentions IAM + `infra/`)

- [ ] **Step 2: Create the expected output fixture**

Write to `orchestrator-kit/docs/fixtures/expected-PLAN-99-freeform.md`:

````markdown
# PLAN-99-freeform — receipts feature (regression fixture)

Reference shape `/plan-format` is expected to produce from
`freeform-plan-input.md`. Not byte-for-byte enforced (Claude may
phrase task bodies differently); validates structural correctness
via `ingest-plan.sh`.

## Task 1: Add a receipt template module
**depends_on:** []
**touches:** [`src/receipts/template.py`]

Expose `render_receipt(order)` returning HTML.

## Task 2: Add the receipt-sender Lambda
**depends_on:** []
**touches:** [`lambdas/send_receipt/handler.py`, `tests/test_send_receipt.py`]

Uses the template from task 1.

## Task 3: Wire the sender into checkout
**depends_on:** [2]
**touches:** [`src/checkout/handler.py`]

After successful checkout, invoke the receipt-sender.

## Task 4: Add an IAM role for the Lambda
**depends_on:** []
**touches:** [`infra/iam.tf`]

Minimal trust policy for AWS Lambda service. Sensitive — flagged by
ingest auto-detector.

## Task 5: Update docs
**depends_on:** []
**touches:** [`docs/receipts.md`]

User-supplied during gap-fill (input had no explicit file path).
````

- [ ] **Step 3: Sanity-check the expected output against ingest-plan.sh**

Run:
```bash
cd /tmp && rm -rf ingest-fixture-test && mkdir -p ingest-fixture-test/.claude/plans
cp /Users/rb/Documents/Github/claudecode-automation/orchestrator-kit/docs/fixtures/expected-PLAN-99-freeform.md \
   /tmp/ingest-fixture-test/.claude/plans/PLAN-99-freeform.md
cd /tmp/ingest-fixture-test
/Users/rb/Documents/Github/claudecode-automation/orchestrator-kit/.claude/scripts/ingest-plan.sh \
   .claude/plans/PLAN-99-freeform.md
```
Expected: exit 0; print summary showing 5 tasks; `Auto-merge disabled: 4`; state.json written.

If validation fails, the expected fixture is wrong — fix it and re-run. The fixture must be ingest-valid because Task 5's smoke test compares against this shape.

Cleanup:
```bash
rm -rf /tmp/ingest-fixture-test
```

- [ ] **Step 4: Commit**

```bash
cd /Users/rb/Documents/Github/claudecode-automation
git add orchestrator-kit/docs/fixtures/freeform-plan-input.md \
        orchestrator-kit/docs/fixtures/expected-PLAN-99-freeform.md
git commit -m "test: add regression fixtures for plan-format converter"
```

---

## Task 3: Create the `/plan-format` slash command

**Goal:** Write the slash command file that converts a freeform plan into PLAN-NN-slug format.

**Files:**
- Create: `orchestrator-kit/.claude/commands/plan-format.md`

- [ ] **Step 1: Ensure target directory exists**

```bash
mkdir -p /Users/rb/Documents/Github/claudecode-automation/orchestrator-kit/.claude/commands
```

- [ ] **Step 2: Write the slash command file**

Write to `orchestrator-kit/.claude/commands/plan-format.md`:

````markdown
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
````

- [ ] **Step 3: Verify file syntax**

```bash
head -10 /Users/rb/Documents/Github/claudecode-automation/orchestrator-kit/.claude/commands/plan-format.md
```
Expected: frontmatter delimited by `---` lines, contains `description:`, `argument-hint:`, `allowed-tools:`.

- [ ] **Step 4: Commit**

```bash
cd /Users/rb/Documents/Github/claudecode-automation
git add orchestrator-kit/.claude/commands/plan-format.md
git commit -m "feat(commands): add /plan-format slash command for plan conversion"
```

---

## Task 4: Set up smoke test environment

**Goal:** Install the kit (current branch) into the sacrificial test target repo and prepare it to receive the new artifacts.

**Files:** none in this repo. Operates on `/Users/rb/Documents/Github/claudecode-test-target`.

- [ ] **Step 1: Confirm test target repo exists and is clean**

```bash
cd /Users/rb/Documents/Github/claudecode-test-target
git status
```
Expected: clean working tree, on `main`. If dirty, ask the user before proceeding — don't auto-stash.

If the directory doesn't exist, clone it first:
```bash
gh repo clone weclaudecode/claudecode-test-target /Users/rb/Documents/Github/claudecode-test-target
```

- [ ] **Step 2: Create a smoke-test branch in the target repo**

```bash
cd /Users/rb/Documents/Github/claudecode-test-target
git checkout -b smoke/plan-authoring-tools
```

- [ ] **Step 3: Copy the kit's current state into the test target**

Follow the existing installer pattern from `orchestrator-kit/README.md`'s "Install into a repo" section. Run the commands it specifies, sourced from `/Users/rb/Documents/Github/claudecode-automation/orchestrator-kit/`.

If Task 1's resolution requires an extra step for project-level skills, perform that here too.

After install, verify:
```bash
ls .claude/commands/plan-format.md
ls .claude/skills/plan-author/SKILL.md 2>/dev/null || echo "skill not installed yet (expected — Task 6)"
ls .claude/scripts/ingest-plan.sh
ls docs/PLAN-FORMAT.md 2>/dev/null || ls .claude/PLAN-FORMAT.md 2>/dev/null
```
Expected: `plan-format.md` present, `ingest-plan.sh` present, `PLAN-FORMAT.md` reachable somewhere the artifact can find it.

- [ ] **Step 4: Copy the input fixture into the test target**

```bash
mkdir -p docs/fixtures
cp /Users/rb/Documents/Github/claudecode-automation/orchestrator-kit/docs/fixtures/freeform-plan-input.md \
   docs/fixtures/freeform-plan-input.md
```

- [ ] **Step 5: Confirm `.claude/plans/` exists**

```bash
mkdir -p .claude/plans
ls .claude/plans/
```
Expected: directory exists (may be empty).

No commit yet — the smoke-test branch is throwaway. We'll keep it local for Tasks 5 and 7.

---

## Task 5: Smoke test `/plan-format` against the fixture

**Goal:** Confirm the slash command converts the fixture into a valid PLAN file that `ingest-plan.sh` accepts.

**Files:** Operates on `/Users/rb/Documents/Github/claudecode-test-target`.

- [ ] **Step 1: Launch a Claude Code session in the test target repo**

Open a new Claude Code session at `/Users/rb/Documents/Github/claudecode-test-target` on the `smoke/plan-authoring-tools` branch.

- [ ] **Step 2: Run the slash command**

In that session, run:
```
/plan-format docs/fixtures/freeform-plan-input.md receipts
```
Expected behavior:
- The command reads PLAN-FORMAT.md, parses the input.
- Confidently emits depends_on/touches for tasks 1-4.
- Asks ONE batched gap-fill question for task 5 (`touches`).
- Provide a sensible answer (e.g., `docs/receipts.md`).
- The command runs `ingest-plan.sh` and exits 0.

- [ ] **Step 3: Verify the output**

After the command completes, run:
```bash
cd /Users/rb/Documents/Github/claudecode-test-target
ls .claude/plans/
```
Expected: `PLAN-01-receipts.md` and `PLAN-01-receipts.state.json` exist.

```bash
jq '.total_tasks, .auto_merge_overrides | keys' .claude/plans/PLAN-01-receipts.state.json
```
Expected:
```
5
["4"]
```

- [ ] **Step 4: Diff against the expected fixture**

```bash
diff -u \
  /Users/rb/Documents/Github/claudecode-automation/orchestrator-kit/docs/fixtures/expected-PLAN-99-freeform.md \
  .claude/plans/PLAN-01-receipts.md | head -80
```
This is a sanity comparison, not a strict equality check. Expect differences in title prose and body phrasing. The shape (5 tasks, depends_on/touches lines, sensitive flag on task 4) must match.

If the shape is wrong (e.g., task count differs, task 4 missing from `auto_merge_overrides`, ingest exits 1 after gap-fill), the slash command prompt has a bug — record what failed, return to Task 3, edit the prompt, repeat Task 5.

- [ ] **Step 5: Clean up the test target (keep branch local)**

```bash
cd /Users/rb/Documents/Github/claudecode-test-target
rm -rf .claude/plans/PLAN-01-receipts.md .claude/plans/PLAN-01-receipts.state.json
```

Leave the branch in place — Task 7 will reuse it for the skill smoke test.

- [ ] **Step 6: No commit** — smoke runs don't produce kit-side changes by themselves. If Task 3's prompt was edited during this task, commit those edits now:

```bash
cd /Users/rb/Documents/Github/claudecode-automation
git status
# if plan-format.md is modified:
git add orchestrator-kit/.claude/commands/plan-format.md
git commit -m "fix(commands): tighten /plan-format prompt based on smoke test"
```

---

## Task 6: Create the `plan-author` skill

**Goal:** Write the interactive skill that designs a plan from scratch via brainstorm → decompose → detail → emit.

**Files:**
- Create: `orchestrator-kit/.claude/skills/plan-author/SKILL.md`

- [ ] **Step 1: Ensure target directory exists**

```bash
mkdir -p /Users/rb/Documents/Github/claudecode-automation/orchestrator-kit/.claude/skills/plan-author
```

- [ ] **Step 2: Write the skill file**

Write to `orchestrator-kit/.claude/skills/plan-author/SKILL.md`:

````markdown
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
````

- [ ] **Step 3: Verify file syntax**

```bash
head -5 /Users/rb/Documents/Github/claudecode-automation/orchestrator-kit/.claude/skills/plan-author/SKILL.md
```
Expected: frontmatter delimited by `---`, contains `name: plan-author` and a `description:` line.

- [ ] **Step 4: Commit**

```bash
cd /Users/rb/Documents/Github/claudecode-automation
git add orchestrator-kit/.claude/skills/plan-author/SKILL.md
git commit -m "feat(skills): add plan-author skill for interactive plan design"
```

---

## Task 7: Smoke test the `plan-author` skill

**Goal:** Confirm the skill triggers on a natural-language request and produces an ingest-valid PLAN file.

**Files:** Operates on `/Users/rb/Documents/Github/claudecode-test-target` (smoke branch from Task 4).

- [ ] **Step 1: Re-sync the test target with the kit's current state**

```bash
cd /Users/rb/Documents/Github/claudecode-test-target
```
Re-run the installer steps from `orchestrator-kit/README.md` to pick up the new skill. If Task 1 found that project-level skills need a copy step, perform it now:
```bash
mkdir -p .claude/skills
cp -r /Users/rb/Documents/Github/claudecode-automation/orchestrator-kit/.claude/skills/* .claude/skills/
```

Verify:
```bash
ls .claude/skills/plan-author/SKILL.md
```

- [ ] **Step 2: Open a fresh Claude Code session in the test target**

Open at `/Users/rb/Documents/Github/claudecode-test-target` on the `smoke/plan-authoring-tools` branch.

- [ ] **Step 3: Confirm the skill is loaded**

In the session, check the available-skills system reminder for `plan-author`. If absent, the loading mechanism is wrong — return to Task 1 and revise the resolution.

- [ ] **Step 4: Trigger the skill via natural language**

Say something like:
> "Help me design an orchestrator plan to add a simple `delete_todo` function to the todoapp library."

Expected:
- The skill triggers (visible in the session as a Skill invocation).
- It asks the Phase 1 brainstorm question(s).
- Provide a goal: "Add `delete_todo(id)` to `src/todoapp/core.py` with tests."
- Task count: 2 (function + tests).
- The skill proposes a decomposition. Approve it.
- The skill writes `.claude/plans/PLAN-NN-delete-todo.md`.
- `ingest-plan.sh` exits 0; summary is printed.

- [ ] **Step 5: Verify the output**

```bash
ls .claude/plans/
jq '.total_tasks' .claude/plans/PLAN-*-delete-todo.state.json
```
Expected: `total_tasks` ≥ 2; state.json present.

- [ ] **Step 6: Clean up**

```bash
rm -f .claude/plans/PLAN-*-delete-todo.md .claude/plans/PLAN-*-delete-todo.state.json
git checkout main
git branch -D smoke/plan-authoring-tools
```

- [ ] **Step 7: Commit any prompt fixes back in the kit**

```bash
cd /Users/rb/Documents/Github/claudecode-automation
git status
# if SKILL.md was modified during smoke testing:
git add orchestrator-kit/.claude/skills/plan-author/SKILL.md
git commit -m "fix(skills): tighten plan-author prompt based on smoke test"
```

---

## Task 8: Document the regression test in PLAN-FORMAT.md

**Goal:** Add a "Conversion regression test" section to `PLAN-FORMAT.md` describing how to re-run the fixture verification after future changes.

**Files:**
- Modify: `orchestrator-kit/docs/PLAN-FORMAT.md`

- [ ] **Step 1: Append the regression section**

Open `orchestrator-kit/docs/PLAN-FORMAT.md`. After the existing "Ingest rejections" section (the last existing section), append:

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
cd /Users/rb/Documents/Github/claudecode-automation
git add orchestrator-kit/docs/PLAN-FORMAT.md
git commit -m "docs(plan-format): add conversion regression test procedure"
```

---

## Task 9: Update README with new entry points

**Goal:** Add a short section to `orchestrator-kit/README.md` pointing users at the two new entry points. If Task 1 found that project-level skills require an install step, add it.

**Files:**
- Modify: `orchestrator-kit/README.md`

- [ ] **Step 1: Read the current README to find the right insertion point**

```bash
grep -n "^##\|^# " /Users/rb/Documents/Github/claudecode-automation/orchestrator-kit/README.md
```
Identify a sensible spot — typically after "Install into a repo" and before any deeper-detail sections.

- [ ] **Step 2: Add a section about the entry points**

Insert this section at the identified spot:

```markdown
## Authoring plans

Two helpers create or import plans in the strict
[`PLAN-FORMAT.md`](docs/PLAN-FORMAT.md) shape that `ingest-plan.sh`
accepts:

- **`/plan-format <input-path> [slug]`** — slash command. Converts a
  freeform plan markdown file into a valid `PLAN-NN-<slug>.md`,
  then runs ingest-plan.sh and iterates on validator errors. Use
  when you already have a plan written and want it formatted.
- **`plan-author` skill** — triggers on phrases like "design an
  orchestrator plan for X". Interactively walks goal →
  decomposition → dep/touches → emit + validate. Use when you're
  starting from a goal, not a draft.

Both write to `.claude/plans/`, do not clobber existing files, and
never commit on your behalf. See
[`SPEC-plan-authoring.md`](docs/SPEC-plan-authoring.md) for the full
design.
```

- [ ] **Step 3: (Conditional) Update the installer steps**

Look up Task 1's recorded resolution in `SPEC-plan-authoring.md`. If it said an install step is required for skills, add to the "Install into a repo" section a line like:

```bash
# If your Claude Code version doesn't auto-load project-level skills:
mkdir -p .claude/skills
cp -r <path-to-kit>/orchestrator-kit/.claude/skills/* .claude/skills/
```

Place it immediately after the existing command-copy step (`cp ... .claude/commands/ .claude/commands/`).

If Task 1 found no install step is needed, skip Step 3 entirely.

- [ ] **Step 4: Commit**

```bash
cd /Users/rb/Documents/Github/claudecode-automation
git add orchestrator-kit/README.md
git commit -m "docs(readme): document /plan-format and plan-author entry points"
```

---

## Task 10: Final review (shellcheck + working-tree sanity)

**Goal:** Confirm nothing else regressed and the working tree is clean.

**Files:** none (audit only).

- [ ] **Step 1: Shellcheck all existing scripts (no new shell, so this is a regression check)**

```bash
cd /Users/rb/Documents/Github/claudecode-automation
shellcheck \
  orchestrator-kit/orchestrator.sh \
  orchestrator-kit/.claude/hooks/*.sh \
  orchestrator-kit/.claude/scripts/*.sh
```
Expected: exit 0 (or only the same pre-existing warnings as on `main` before this branch). If new warnings appear, investigate — they shouldn't, because no shell was added.

- [ ] **Step 2: Confirm the working tree is clean**

```bash
git status
```
Expected: clean (all changes committed) or only untracked files outside the scope of this plan.

- [ ] **Step 3: Confirm the commit log makes sense**

```bash
git log --oneline -10
```
Expected: 7-9 commits covering: resolve loading question, fixtures, /plan-format command, plan-author skill, PLAN-FORMAT.md regression section, README pointer, and any smoke-test fix commits.

- [ ] **Step 4: (Optional, user-discretion) Open a PR**

If the user requests it, open a PR for this branch using the standard kit workflow (see repo CLAUDE.md). Otherwise the work stays on the local branch for the user to push when ready.

---

## Self-review notes

**Spec coverage:** Every section of `SPEC-plan-authoring.md` is addressed:
- Architecture & file layout → Tasks 3, 6, 9 (file map)
- Artifact A: `/plan-format` → Task 3 (creation) + Task 5 (smoke)
- Artifact B: `plan-author` skill → Task 6 (creation) + Task 7 (smoke)
- Shared validation/iterate loop → embedded in both prompts (Tasks 3, 6)
- Naming & numbering policy → embedded in `/plan-format` prompt (Task 3 step 2)
- Edge cases → embedded in both prompts
- Testing strategy → Tasks 2 (fixtures) + Task 8 (regression doc)
- Open implementation questions → Task 1 (resolution) + Task 9 step 3 (conditional installer)

**Placeholder scan:** none — every step has concrete commands and code blocks.

**Type consistency:** N/A — no types. Filenames are consistent across tasks (`PLAN-NN-<slug>.md`, `freeform-plan-input.md`, `expected-PLAN-99-freeform.md`).

**Known soft spots:**
- Tasks 5 and 7 require a separate Claude Code session in the test target. The plan can't automate "open a new session" — the executing engineer (or subagent) needs to coordinate. If running via `subagent-driven-development`, the parent agent should drive the test-target session and the subagent should focus on the kit-side edits.
- Task 1's empirical test relies on inspecting a live session's available-skills list. If the engineer can't easily do that, falling back to docs-only is acceptable.
