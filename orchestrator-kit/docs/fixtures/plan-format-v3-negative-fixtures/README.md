# PLAN-FORMAT v3 negative fixtures

Each `.md` file here is a deliberately invalid plan that
`ingest-plan.sh` must reject (exit non-zero) with a clear stderr
message naming the offending field.

## What each fixture exercises

| File | Failure mode |
|---|---|
| `bad-unknown-frontmatter-key.md` | Unknown top-level frontmatter key |
| `bad-env-value.md` | `env:` value not in dev/staging/prod |
| `bad-aws-missing-subkey.md` | `aws:` block missing required sub-keys |
| `PLAN-99-bad-requires-self.md` | `requires:` contains self-reference (PLAN-99 in PLAN-99); filename keeps the `PLAN-99-` prefix because the self-ref check is derived from the source filename slug |
| `bad-deploy-mode-value.md` | Per-task `deploy_mode:` value not operator/autonomous |
| `bad-autonomous-no-aws.md` | Task uses `deploy_mode: autonomous` but no `aws:` block |
| `bad-empty-checklist.md` | `pre_flight.checklist` is empty |

## Running as a regression test

From a directory where copies of these fixtures live (ingest-plan.sh
refuses to overwrite existing state files, so re-run after `rm -f`):

```sh
cd "$(mktemp -d)"
cp /path/to/orchestrator-kit/docs/fixtures/plan-format-v3-negative-fixtures/*.md .
for f in *bad-*.md; do
  echo "=== $f ==="
  if /path/to/orchestrator-kit/.claude/scripts/ingest-plan.sh "$f" >/dev/null 2>err.log; then
    echo "FAIL: $f was accepted (should have been rejected)"
  else
    head -1 err.log
  fi
done
```

Each fixture should produce a non-zero exit and a single-line error
message identifying the offending field. None of them should produce
a `.state.json` file — failed validation has no partial side effects.

## Naming convention

`bad-<short-tag>.md` so the fixture's filename describes what it tests.
Keep each fixture minimal: one failure mode per file, smallest task
content that still parses. The `PLAN-99-bad-requires-self.md` fixture
breaks the pattern because the self-reference validator reads the
source filename to derive the plan's slug — without a `PLAN-NN-` prefix
the check would be a no-op.
