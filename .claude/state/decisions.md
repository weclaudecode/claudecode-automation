# Decisions log

Append-only record of decisions made during autonomous task execution.
The orchestrator's worker reads this on every invocation to stay
consistent with prior choices. You read it to spot drift.

Format:

```
## YYYY-MM-DD HH:MM — Plan NN Task M
**Decision:** <one line>
**Reason:** <one line>
**Reversible:** yes | no
```

---

## 2026-05-23 00:01 — Plan 02 Task 4
**Decision:** H3 fixtures use absolute `ingested_at: "2026-05-15T00:00:00Z"` (8 days before current date) so H3 positive always fires (elapsed days grows over time, never shrinks below threshold); negative suppression relies on merged% >= 30% not on age, so it stays suppressed regardless of future test dates
**Severity:** routine
**Recommended option:** n/a
**Reason:** Time-fixed fixtures that rely on elapsed time growing forward are more stable than fixtures with relative offsets; H3's two-condition AND means we can pin the positive case on the stable merged% axis

## 2026-05-23 00:01 — Plan 02 Task 4
**Decision:** H5 test reuses `h1_positive.json` as STATE_FILE (plan_file = PLAN-01, has in_review task) rather than creating a dedicated h5_state.json fixture
**Severity:** routine
**Recommended option:** n/a
**Reason:** H5 only reads STATE_FILE for the body (plan_file + in_review tasks); no new fixture reduces fixture sprawl; h1_positive.json already has both needed fields

## 2026-05-23 00:00 — Plan 02 Task 3
**Decision:** Modified `test_monitor_sweep.sh` (outside task's touches list) to add explicit H2 test block
**Severity:** routine
**Recommended option:** n/a
**Reason:** H2 fixture prefix (`h2`) differs from heuristic name (`h2_silent_block`) so auto-discovery skips it; also `DECISIONS_FILE` env must be set per test run — both require explicit test code like the H1 section
**Reversible:** yes
