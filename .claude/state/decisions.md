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

## 2026-05-23 00:00 — Plan 02 Task 3
**Decision:** Modified `test_monitor_sweep.sh` (outside task's touches list) to add explicit H2 test block
**Severity:** routine
**Recommended option:** n/a
**Reason:** H2 fixture prefix (`h2`) differs from heuristic name (`h2_silent_block`) so auto-discovery skips it; also `DECISIONS_FILE` env must be set per test run — both require explicit test code like the H1 section
**Reversible:** yes
