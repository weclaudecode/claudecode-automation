# PLAN-SMOKE — exercises scheduler edge cases

Smoke-test fixture for the Phase 1 ingest and Phase 4 scheduler.

Covers:
- Task with no deps (1)
- Single-dep chain (2 depends on 1)
- Parallel-safe pair (2 and 3 both depend on 1; touches are disjoint)
- Sensitive-flagged task that must NOT auto-merge (4)

Expected ingest behavior (validates after Phase 1 ships):
- 4 GitHub issues created
- Task 1 carries `orch:deps-met` (no deps)
- Tasks 2 and 3 do NOT carry `orch:deps-met` (waiting on 1)
- Task 4 carries `orch:needs-robbie` + `auto_merge_overrides[4] = false`

Expected scheduler behavior (validates after Phase 4 ships, MAX_PARALLEL=2):
- Tick 1: launches task 1 only (no other ready tasks)
- After task 1 merges: tasks 2 and 3 both become `orch:deps-met`
- Tick 2: launches tasks 2 and 3 in parallel (disjoint `touches:`)
- Task 4 is always ready (deps-met from start) but goes through manual
  review path due to needs-robbie flag

---

## Task 1: Add util module
**depends_on:** []
**touches:** [`src/utils/format.ts`]

Add a `formatBytes(n: number)` helper that returns a human-readable
size string. Commit message: `feat: add formatBytes util`.

## Task 2: Use util in component A
**depends_on:** [1]
**touches:** [`src/components/A.tsx`]

Import formatBytes from `src/utils/format.ts`; render the result
inside component A. Commit message: `feat: use formatBytes in A`.

## Task 3: Use util in component B
**depends_on:** [1]
**touches:** [`src/components/B.tsx`]

Import formatBytes from `src/utils/format.ts`; render the result
inside component B. Commit message: `feat: use formatBytes in B`.

## Task 4: Add IAM role (must NOT auto-merge)
**depends_on:** []
**touches:** [`infra/iam.tf`]

Add `aws_iam_role.formatter_writer` with a minimal trust policy.
Commit message: `feat(infra): add formatter_writer IAM role`.
