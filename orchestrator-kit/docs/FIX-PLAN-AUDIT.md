# FIX-PLAN audit (2026-05-17)

Cross-reference of FIX-PLAN.md tasks against current orchestrator-kit/ code.

## Summary

All six Phase 1 safety-net fixes (1.1-1.6) and all three Phase 2 reviewer-
reliability fixes (2.1-2.3) have landed correctly. All four Phase 3 cost &
ergonomics fixes (3.1-3.4) are in place. Of Phase 4 polish, M1 (pre-extract
task) and M2 (retry-aware RUN_OUT) and M3 (log rotation) and M6 (notify
fall-through) and M4 (decision-tier examples + Tier-3 backstop) have all
landed; M5 (defaults vs CLAUDE.md split) and M7 (worktree-prune sidecar)
remain partial/documentation-only. No critical or high-severity fix is
missing — it is safe to begin SDLC-EVOLUTION-PLAN Phase 0 work.

Note on line-number drift: FIX-PLAN.md references `orchestrator.sh:29-33`,
`:77-80`, `:130`, `:147-155`, `:162-175` and `ingest-plan.sh:66-89` from the
2026-05-09 state. Current `orchestrator.sh` is 289 lines (was ~175 in the
diff baseline) and the cited regions have all been reorganized; this audit
maps each task to its current location.

## Per-task status

| Task | Status | Evidence | Notes |
|---|---|---|---|
| P0.1 | N/A | — | Phase 0 is a reproducer, not a fix |
| P0.2 | N/A | — | Phase 0 is a reproducer, not a fix |
| P0.3 | N/A | — | Phase 0 is a reproducer, not a fix |
| 1.1 (C4 gawk) | DONE | `.claude/scripts/ingest-plan.sh:16-22,43,94`; `README.md:12-15,20` | `command -v gawk` guard at top; both awk calls use `"$GAWK"`; README Prerequisites lists gawk with rationale |
| 1.2 (C2 SKIP_REVIEW) | DONE | `.claude/hooks/stop-pre-push-review.sh:75` | `RESPONSE=$(SKIP_REVIEW=1 claude -p ...)`; hook short-circuits on SKIP_REVIEW at line 17 |
| 1.3 (C3 worktree/cd) | DONE | `orchestrator.sh:133-137,211` | `worktree add` chain ends with `|| { ... exit 1; }`; both `cd "$WT"` calls guarded with explicit error+exit |
| 1.4 (C6 push/gh) | DONE | `orchestrator.sh:212-223,244-248` | `git push` captures stderr, notifies, exits 1 without advancing state; `gh pr create` failure also notifies + exits |
| 1.5 (C1 PID lock) | DONE | `orchestrator.sh:41-60` | `mkdir`+pid-file, stale-PID detection via `kill -0`, `rm -rf` cleanup (lockdir contains pid), trap installed in both fresh and stale-break paths; also handles race after break (line 53) |
| 1.6 (C5 pending PR) | DONE | `orchestrator.sh:84-108,258-283` | Pending-PR gate at top of tick handles MERGED/CLOSED/other; auto-merge path records `pending_pr` instead of advancing; non-auto path still advances (per FIX-PLAN diff) |
| 2.1 (H1 fence-aware awk) | DONE | `.claude/scripts/ingest-plan.sh:43-48,94-96`; `.claude/hooks/stop-pre-push-review.sh:42-49`; `orchestrator.sh:146-153` | Fence-tracking blocks present in ingest task-count, ingest sensitive scan, hook task-extract, and orchestrator task-extract |
| 2.2 (H2 origin/main diff) | DONE | `.claude/hooks/stop-pre-push-review.sh:59-64` | `git diff origin/main...HEAD` is primary; local `main` is a fallback; empty diff exits 0 |
| 2.3 (H3 JSON extraction) | DONE | `.claude/hooks/stop-pre-push-review.sh:99-117,124` | Balanced-brace awk extractor produces `REVIEW_JSON`; both `PASS` and `BLOCKERS` parse `$REVIEW_JSON` not raw `$REVIEW_TEXT` |
| 3.1 (H5 model/turns) | DONE | `orchestrator.sh:161-162,184-185`; `README.md:80-88` | `WORKER_MODEL` and `MAX_TURNS` env-overridable; defaults sonnet/30; README cost-knobs table documents them |
| 3.2 (H7 permissions) | DONE | `README.md:54-78` | Full "Required permissions allowlist" section between "Install" and "Cost knobs" with concrete `permissions.allow` example |
| 3.3 (H4 sensitive patterns) | DONE | `.claude/scripts/ingest-plan.sh:60-85` | Patterns broadened (PublicAccessBlock, BucketPolicy, FunctionUrl, NetworkAcl, `0.0.0.0/0`, alter/drop table, `terraform/(prod\|production)/`) with comment block explaining the `\.`→`[.]`, `\*`→`[*]` escaping choice |
| 3.4 (H6 archive dir) | DONE | `orchestrator.sh:25,114-115` | `mkdir -p .claude/plans/archive` runs every tick; `mv` to archive has no `2>/dev/null || true` suppression |
| 4.1 (M1 pre-extract) | DONE | `orchestrator.sh:146-153,179-181` | `TASK_CONTENT` extracted from plan once and inlined verbatim into the worker prompt |
| 4.2 (M2 retry RUN_OUT) | DONE | `orchestrator.sh:141` | `RUN_OUT=...-r${RETRIES}.json` — retries no longer overwrite |
| 4.3 (M3 log rotation) | DONE | `orchestrator.sh:22,27-33`; `README.md:88,173-174` | Size-based rotation (default 10 MiB, `ORCH_LOG_MAX_BYTES` override) with timestamped suffix; README documents it |
| 4.4 (M4 tier examples) | DONE | `.claude/prompts/worker-superpower.md:22-58` | Concrete "Examples (not exhaustive)" lists for all 3 tiers; explicit "Backstop — when no tier rule clearly applies: Default to Tier 3" at line 55 |
| 4.5 (M5 defaults/CLAUDE split) | PARTIAL | `CLAUDE.md`, `.claude/defaults.md` | Some separation exists (CLAUDE.md has must-rules/conventions; defaults.md has when-in-doubt resolutions), but defaults.md still codifies architecture/code/test standards (e.g. Python `from __future__ import annotations`, DynamoDB-single-table) that read like CLAUDE.md must-haves rather than tie-breakers. FIX-PLAN treats this as M-tier non-blocking |
| 4.6 (M6 notify fall-through) | DONE | `.claude/scripts/notify.sh:24-43` | Slack and Discord branches both wrap the curl in `if`; on failure they log "delivery failed, falling through" and continue to the next channel rather than `exit 0` |
| 4.7 (M7 worktree prune sidecar) | PARTIAL | `README.md:165-171` | Documented as an example cron line ("Sidecar — prune abandoned worktrees on Sundays at 3am") but no shipped script or installer; treated as operator-managed |

## Blockers for new work

None — safe to proceed with SDLC-EVOLUTION-PLAN Phase 0.

Specifically, the files the SDLC evolution will modify are clean:
- `orchestrator.sh` — all C/H findings fixed; pending-PR gate (1.6) and PID
  lock (1.5) are exactly the substrate the Phase 4 collision-detector
  replaces, so they're in place for the transition.
- `.claude/scripts/ingest-plan.sh` — gawk-required, fence-aware, broadened
  patterns. SDLC Phase 1 will extend its frontmatter parsing on top of a
  sound base.
- `.claude/hooks/stop-pre-push-review.sh` — reviewer is non-recursive
  (1.2), diff base is correct (2.2), JSON extraction is robust (2.3). SDLC
  Phase 3's PR-comment reviewer can reuse the extractor.
- `.claude/prompts/worker-superpower.md` — tier examples + Tier-3 backstop
  are in. SDLC Phase 2's `ORCH_AUTO_RECOMMENDED` change documents exactly
  which tier examples become auto-decided.

Non-blocking residuals to track but not gate on:
- M5 (defaults.md vs CLAUDE.md): the SDLC plan does not edit these.
- M7 (worktree-prune sidecar): documented-only; SDLC Phase 4 introduces
  parallel worktrees and may want to ship the sidecar script then.
