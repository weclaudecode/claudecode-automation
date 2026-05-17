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
