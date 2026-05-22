# PLAN-01 — add status section to README

Minimal one-task example plan demonstrating the kit's PLAN-NN-<slug>.md
format. Suitable for first-run after install: ingest it, watch one
worker tick run end-to-end, and confirm the kit is wired up correctly
against your repo + branch protection.

## Task 1: Add a Status section to README.md
**depends_on:** []
**touches:** [`README.md`]

Insert a `## Status` section directly under the README's main title.
The section should be a single line stating the project's current
maturity level — operator picks the wording; anything like
`Status: experimental — APIs may change` is fine.

Steps:
1. Read the existing `README.md`. Identify the line immediately after
   the `# <project title>` header.
2. Insert a new `## Status` section as the first subsection under the
   title. Use a one-line body — keep it terse.
3. Verify the change: `head -10 README.md` shows the new section
   above the existing content.

Commit: `docs: add Status section to README`
