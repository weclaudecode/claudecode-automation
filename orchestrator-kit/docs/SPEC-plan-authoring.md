# SPEC — Plan authoring tooling

Design spec for two new entry points that produce orchestrator
`.claude/plans/PLAN-NN-<slug>.md` files: a slash command for converting
existing freeform plans, and a skill for authoring new plans
interactively. Both target the format defined in
[`PLAN-FORMAT.md`](PLAN-FORMAT.md) and validate via
`.claude/scripts/ingest-plan.sh`.

Status: approved 2026-05-19. Implementation plan: TBD (handed off to
superpowers:writing-plans).

## Summary

Add two artifacts to the orchestrator-kit so plans authored or converted
by a Claude session land in a shape `ingest-plan.sh` will accept on the
first or second try:

- `/plan-format <input> [slug]` — slash command, deterministic
  converter. Reads a freeform plan markdown file, infers fields, emits
  `PLAN-NN-<slug>.md`, runs ingest, iterates on validator errors.
- `plan-author` — skill that triggers on "design a plan for the
  orchestrator" intent. Brainstorms goal, decomposes into tasks, fills
  fields, emits the same output and runs the same validator.

Both shell out to the existing `ingest-plan.sh` and never duplicate
its parsing or sensitive-pattern logic.

## Motivation

The orchestrator's PLAN format is strict (validated by `ingest-plan.sh`
with no partial-state writes on failure). Users with rough plans or
spec docs have to manually re-shape them into the required header
triplet (`## Task N:` + `**depends_on:**` + `**touches:**`) before
ingest will accept them. This is mechanical work that a Claude session
can do faster and more consistently, and it's a recurring need any
time someone starts a new plan against a target repo.

Two flows exist in practice and have different ergonomics:

- **Convert:** "I already have a plan written, format it" — one-shot,
  file in, file out, no real conversation needed.
- **Author:** "Help me design a plan for goal X" — interactive,
  branches on user goals, decomposes from scratch.

A single artifact handling both bloats trigger logic; two narrow
artifacts trigger more reliably and each has a tighter prompt.

## Architecture & file layout

```
orchestrator-kit/
  .claude/
    commands/
      plan-format.md              # NEW — slash command (converter)
    skills/                       # NEW directory
      plan-author/
        SKILL.md                  # NEW — author skill (interactive)
  docs/
    PLAN-FORMAT.md                # existing — canonical spec, both read this
    SPEC-plan-authoring.md        # this file
  README.md                       # MINOR — short pointer to the two entry points
```

No new shell scripts. No changes to `ingest-plan.sh`. No new runtime
dependencies — neither artifact requires anything beyond what the kit
already needs (`gawk`, `jq`, `python3`, `gh`, `git`, `claude`).

When the kit installer copies the kit into a target repo, both
artifacts land at `<repo>/.claude/commands/plan-format.md` and
`<repo>/.claude/skills/plan-author/SKILL.md` and are immediately
available to Claude Code sessions in that repo.

### Verification flagged for implementation

Confirm Claude Code loads project-level skills from
`<repo>/.claude/skills/<name>/SKILL.md`. If the harness only loads
skills from `~/.claude/skills/`, the kit's installer (the "Install
into a repo" section of `README.md`) must add a one-line symlink or
copy step. This is a 1-line install adjustment, not an architectural
change.

## Artifact A: `/plan-format` slash command

### Frontmatter

```yaml
---
description: Convert a freeform plan markdown into orchestrator PLAN-NN-slug.md format and validate via ingest-plan.sh
argument-hint: <input-path> [slug]
allowed-tools: Read, Write, Edit, Bash, AskUserQuestion, Grep, Glob
---
```

### Invocation

```
/plan-format <input-path> [slug]
```

- `<input-path>` — required, path to a freeform plan or notes markdown
  file. Relative to repo root.
- `[slug]` — optional, kebab-case slug for the output filename.
  Inferred if omitted (see Naming & numbering).

### Flow

1. Read `<input-path>` and `orchestrator-kit/docs/PLAN-FORMAT.md` (or
   the in-repo copy after install — same content).
2. Pick the next `PLAN-NN` by globbing `.claude/plans/PLAN-*.md`,
   taking the max integer, incrementing, zero-padding to 2 digits.
3. For each candidate task in the input, classify each field
   (`depends_on`, `touches`) as either **confident** (an explicit
   file path or task reference appears in the body) or
   **low-confidence** (inferred from prose, ambiguous, or missing).
4. Emit a first-draft `.claude/plans/PLAN-NN-<slug>.md`.
5. Run `.claude/scripts/ingest-plan.sh <output-path>`. On pass →
   print the state.json summary and exit. On fail → see "Shared
   validation & iterate loop" below.

## Artifact B: `plan-author` skill

### Frontmatter

```yaml
---
name: plan-author
description: Use when the user wants to design a new implementation plan for the Claude Code orchestrator (PLAN-NN-slug.md). Triggers on phrases like "design an orchestrator plan", "plan for the orchestrator to run", "create an orchestrator plan for X", or "draft a PLAN-NN file". Walks user through goal → decomposition → dep/touches → emit + validate.
---
```

The description is deliberately tight to the orchestrator. It must not
fire on generic "plan for X" requests, only on orchestrator plans.

### Flow

1. Read `orchestrator-kit/docs/PLAN-FORMAT.md` for current rules.
2. **Brainstorm phase** (lightweight, not full `superpowers:brainstorming`):
   - One question: goal of the plan (1–3 sentences) + target repo path.
   - One question: rough task count + any tasks the user already has
     in mind.
3. **Decompose phase:** propose 3–8 task titles. Get a thumbs-up or edits.
4. **Detail phase:** fill in `depends_on` and `touches` per task.
   Confident inferences silent, low-confidence ones batched into one
   `AskUserQuestion`.
5. **Emit + validate:** same as `/plan-format` step 4 onward — write
   file, run `ingest-plan.sh`, iterate ≤3 times, gap-fill once.

## Shared validation & iterate loop

Both artifacts encode the same loop in their prompts (no shared
script — prose is sufficient).

```
attempts = 0
emit draft
loop while attempts < 3:
  run ingest-plan.sh
  if pass: print summary, exit 0
  parse stderr (lines like "task N: <kind>")
  classify each error:
    auto-fixable     (typo in depends_on number, malformed glob,
                      slug rule violation)
    needs-user-input (missing/empty touches, ambiguous deps,
                      cycle, unknown-task reference with no
                      obvious fix)
  if any auto-fixable: apply patches, attempts++, continue loop
  else: break  # only needs-user errors remain
emit ONE AskUserQuestion with the pending list
apply answers
re-run ingest-plan.sh, exit on result (raw stderr on fail)
```

### Bounds

- Max 3 auto-fix iterations.
- Max 1 gap-fill round.
- If ingest still fails after that, emit non-zero, print raw
  `ingest-plan.sh` stderr verbatim. User fixes by hand.

### Error categorization (used by both artifacts)

| Stderr pattern (substring) | Class |
|---|---|
| `depends_on references nonexistent task` | auto-fixable if a typo (off-by-one); else needs-user |
| `depends_on includes itself` | auto-fixable (drop self-ref) |
| `**touches:** must be present and non-empty` | needs-user |
| `cycle:` | needs-user |
| `parser produced invalid JSON` | bail — print raw stderr, exit |
| `gawk required` / `jq required` / `python3 required` | bail — surface verbatim |

## Naming & numbering policy

### Output filename: `.claude/plans/PLAN-NN-<slug>.md`

- **NN selection:** glob `PLAN-*.md`, take max integer, increment.
  Zero-pad to 2 digits. If max is 99, refuse with "use 3-digit
  numbering or archive old plans."
- **Slug rules:** lowercase, kebab-case, ASCII alphanumerics +
  hyphens, max 40 chars. Derivation precedence:
  1. `[slug]` argument if given
  2. Input filename stem (strip leading `PLAN-NN-` if present)
  3. Input H1 title, slugified
  4. If all three empty/invalid → ask via AskUserQuestion
- **Refuse-and-stop conditions:**
  - `.claude/plans/` doesn't exist → "orchestrator kit not installed
    in this repo" + abort
  - Target `PLAN-NN-<slug>.md` already exists → "delete it first or
    pick a different slug" + abort (no clobber)
  - Existing `.state.json` for the chosen NN → same as above
    (`ingest-plan.sh` enforces this; we mirror)

## Edge cases

| Case | Behavior |
|---|---|
| Input has no clear task structure (wall of prose) | `/plan-format`: refuse with "input has no recognizable task structure — try the `plan-author` skill instead." Skill: ask user to point out boundaries. |
| Input mentions IAM/migrations but no explicit `auto_merge: false` | Don't pre-emit `auto_merge: false`. Trust `ingest-plan.sh`'s sensitive-pattern detector. Over-flagging would double-tag. |
| Input has partial PLAN format (some `**depends_on:**` lines, missing `**touches:**`) | Preserve confident user-supplied lines verbatim. Only infer missing fields. Never rewrite user input. |
| `gawk` / `jq` / `python3` missing | Surface `ingest-plan.sh` stderr verbatim. Don't work around. |
| Cycle in inferred deps | Print cycle path from ingest stderr, ask user which dep to drop in batched gap-fill. |
| `/plan-format` invoked on a file already in `.claude/plans/` | Refuse — "input and output would collide. Copy to a draft path first." |
| Input file doesn't exist | Refuse — print path, exit. |
| No `[slug]` and no inferrable slug | Ask once via AskUserQuestion before any write. |

## Testing strategy

The kit has no formal test suite. The closest precedent is fixture
plans under `orchestrator-kit/docs/fixtures/` (`PLAN-SMOKE.md`,
`PLAN-02-cloudtrail-agent.md`). The implementation plan adds:

1. **Two new fixtures** under `orchestrator-kit/docs/fixtures/`:
   - `freeform-plan-input.md` — a deliberately rough plan (mixed
     prose + bullet tasks, some missing globs) that the converter
     should handle.
   - `expected-PLAN-99-freeform.md` — reference expected output
     shape. Not a byte-for-byte assertion target; formatting may
     drift between Claude versions. Used as a sanity reference.
2. **A manual regression checklist** added to `PLAN-FORMAT.md` (new
   section "Conversion regression test"):
   - Run `/plan-format docs/fixtures/freeform-plan-input.md` in a
     sacrificial test target.
   - Confirm `ingest-plan.sh` accepts the output.
   - Confirm `state.json.tasks` has the expected count and that
     `auto_merge_overrides` matches the expected sensitive-flag set.
3. **Shellcheck:** no new shell, so no new shellcheck targets. The
   existing `shellcheck orchestrator-kit/orchestrator.sh
   orchestrator-kit/.claude/hooks/*.sh
   orchestrator-kit/.claude/scripts/*.sh` invocation remains the
   regression check.

## Out of scope (explicit YAGNI)

- Conversion **to** other formats. One-way: freeform → PLAN.
- Re-conversion or re-authoring of an already-formatted plan. Edit
  by hand if changes are needed.
- Multi-file plans (plans spanning multiple `.md`s). Single-file in,
  single-file out.
- GitHub issue creation. That's `.claude/scripts/create-issues.sh`'s
  job; both artifacts stop after a clean ingest.
- Commit auto-creation. Both artifacts emit the file; the user commits.
- Modifying `ingest-plan.sh` itself. Both artifacts treat it as a
  black-box validator and trust its stderr contract.

## Open implementation questions (handed off to plan)

1. Confirm Claude Code loads project-level skills from
   `<repo>/.claude/skills/<name>/SKILL.md`. If not, plan must add an
   installer step.
2. Exact `argument-hint:` syntax for the slash command's optional
   `[slug]` arg — verify against current Claude Code docs.
3. Whether the README pointer should live in `orchestrator-kit/README.md`
   (kit-level) or also in the installer-template `CLAUDE.md` (target-repo
   level after install). Likely both, brief.

### Resolution (Task 1 of IMPL-plan-authoring)

**Project-level skill loading:** YES — Claude Code auto-loads from `<repo>/.claude/skills/`.

Verification method: docs research on 2026-05-20 against `~/.claude/cache/changelog.md`
(empirical test deferred — requires a fresh Claude Code session a subagent cannot launch).

Key evidence from the changelog:

- v2.1.0 entry: "Added automatic skill hot-reload - skills created or modified in
  `~/.claude/skills` **or `.claude/skills`** are now immediately available without
  restarting the session" — confirms `.claude/skills/` (project-level) is an auto-loaded
  path alongside `~/.claude/skills/`.
- "Fixed custom agents and skills not being discovered when running from a git worktree —
  project-level `.claude/agents/` and `.claude/skills/` from the main repository are now
  included" — confirms project-level `.claude/skills/` is a first-class concept the
  harness discovers automatically.
- "Fixed project skills without a `description:` frontmatter field not appearing in
  Claude's available skills list" — further confirms project skills are loaded and surfaced.
- "Fixed subagents not discovering project, user, or plugin skills via the Skill tool" —
  shows the loading scope is `(project | user | plugin)`, not `user` only.

Implication for installer: **no installer change needed.** Skills placed at
`<repo>/.claude/skills/<name>/SKILL.md` by the kit installer are automatically picked up
when a Claude Code session opens in that repo. Task 9 of the implementation plan
("add installer step if loading is not automatic") can be marked skipped.
