# Orchestrator Kit — Fix Plan

Derived from the senior code review on 2026-05-09. Sequenced by dependency,
not severity. Each task names the finding ID from the review (C# = critical,
H# = high, M# = medium), the file path and lines that change, the diff, and
a verification step you can run before moving on.

> Do **not** schedule cron until Phase 1 is complete and Phase 2 verification
> passes on a smoke-test plan.

---

## Phase 0 — Reproduce the silent failures (15 min, no edits)

Goal: prove the most dangerous bugs are real on your machine before fixing
them, so you have a regression check.

### P0.1 — Prove C4 (macOS awk silently produces no flags)

```bash
cd /tmp && cat > test-plan.md <<'EOF'
# Test plan

## Task 1: Add IAM role
Touches `aws_iam_role` and `iam.PolicyStatement`.

## Task 2: Update README
Just docs.
EOF

/path/to/orchestrator-kit/.claude/scripts/ingest-plan.sh test-plan.md
jq '.auto_merge_overrides' test-plan.state.json
# Expected on macOS: {}   (BUG — Task 1 should be flagged)
# Expected on Linux/gawk: {"1": false}
```

If `auto_merge_overrides` is `{}` on macOS, C4 is confirmed.

### P0.2 — Prove C1 (stale lock survives crash)

```bash
cd <repo>
mkdir -p .claude/state/orchestrator.lock
ls .claude/state/orchestrator.lock          # exists, no PID file
./orchestrator.sh                            # exits "lock held"
# Without manual `rmdir`, every cron tick now skips forever.
rmdir .claude/state/orchestrator.lock
```

### P0.3 — Prove C5 (state advances before merge)

Inspect `orchestrator.sh:162-175` and walk through the sequence by hand:
`gh pr merge --auto` returns immediately, then state increments. No PR-merged
check exists.

---

## Phase 1 — Safety nets (must land before any unattended run)

These six fixes together close the routes by which the loop silently lands
wrong code, exhausts quota, or wedges itself.

### Task 1.1 — C4: require gawk and call it explicitly

**File:** `.claude/scripts/ingest-plan.sh:66-89`, `README.md`

```diff
+GAWK=$(command -v gawk) || {
+  echo "gawk required: brew install gawk (macOS) / apt install gawk (Linux)" >&2
+  exit 1
+}
-awk -v pat="$PATTERN" '
+"$GAWK" -v pat="$PATTERN" '
   /^## Task [0-9]+/ { ... }
   ...
 ' "$PLAN" | while read -r t; do
```

Update `README.md` Prerequisites + brew line:
```diff
-brew install gh jq          # macOS
+brew install gh jq gawk      # macOS — gawk is required, BSD awk silently breaks pattern detection
```

**Verify:** rerun P0.1 on macOS; expect `{"1": false}`.

### Task 1.2 — C2: fence reviewer recursion with `SKIP_REVIEW=1`

**File:** `.claude/hooks/stop-pre-push-review.sh:65`

```diff
-RESPONSE=$(claude -p "$(cat "$REVIEW_PROMPT_FILE")
+RESPONSE=$(SKIP_REVIEW=1 claude -p "$(cat "$REVIEW_PROMPT_FILE")
```

The hook already short-circuits on `SKIP_REVIEW=1` at line 17, so this just
activates the existing escape hatch.

**Verify:** add a temporary `echo "REVIEWER STARTED" >&2` at line 14 of the
hook. Run a smoke task. Confirm exactly one "REVIEWER STARTED" per task.

### Task 1.3 — C3: hard-fail on worktree/cd errors

**File:** `orchestrator.sh:77-80`

```diff
-git worktree add -B "$BRANCH" "$WT" origin/main 2>/dev/null \
-  || git worktree add -B "$BRANCH" "$WT" main
-
-cd "$WT"
+git worktree add -B "$BRANCH" "$WT" origin/main 2>/dev/null \
+  || git worktree add -B "$BRANCH" "$WT" main \
+  || { echo "worktree add failed for $BRANCH at $WT"; exit 1; }
+
+cd "$WT" || { echo "cd to worktree $WT failed"; exit 1; }
```

Consider adding `set -e` at the top of `orchestrator.sh` instead, but audit
each existing `|| true` first — many of them are intentional. Targeted
guards are safer.

**Verify:**
```bash
mkdir -p ../wt-plan01-t1 && touch ../wt-plan01-t1/conflict
./orchestrator.sh   # should exit 1, not run claude
rm -rf ../wt-plan01-t1
```

### Task 1.4 — C6: catch git push and gh failures

**File:** `orchestrator.sh:130, 147-155`

```diff
 cd "$WT"
-git push -u origin "$BRANCH" --quiet
+if ! git push -u origin "$BRANCH" --quiet 2> /tmp/orch-push.err; then
+  echo "git push failed: $(cat /tmp/orch-push.err)"
+  bash "$NOTIFY" "push failed" "plan $PLAN_NUM task $CURRENT — auth/network"
+  cd "$REPO"
+  # Do NOT advance state, do NOT increment retry. Operator fixes auth, next tick retries.
+  exit 1
+fi
```

Pair with leaving the worktree in place so the next tick's
`git worktree remove --force` is the cleanup point.

**Verify:** `gh auth logout` then trigger one tick; expect "push failed"
log line, no PR opened, state unchanged.

### Task 1.5 — C1: PID-aware lockdir

**File:** `orchestrator.sh:29-33`

```diff
-if ! mkdir "$LOCKDIR" 2>/dev/null; then
-  echo "lock held, skipping"
-  exit 0
-fi
-trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
+acquire_lock() {
+  if mkdir "$LOCKDIR" 2>/dev/null; then
+    echo $$ > "$LOCKDIR/pid"
+    trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT
+    return 0
+  fi
+  local stale
+  stale=$(cat "$LOCKDIR/pid" 2>/dev/null || echo "")
+  if [ -n "$stale" ] && ! kill -0 "$stale" 2>/dev/null; then
+    echo "stale lock from PID $stale — breaking"
+    rm -rf "$LOCKDIR"
+    mkdir "$LOCKDIR" || return 1
+    echo $$ > "$LOCKDIR/pid"
+    trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT
+    return 0
+  fi
+  echo "lock held by PID ${stale:-?}, skipping"
+  return 1
+}
+acquire_lock || exit 0
```

Note `rm -rf` instead of `rmdir` because the lockdir now contains `pid`.

**Verify:**
```bash
mkdir -p .claude/state/orchestrator.lock
echo 99999999 > .claude/state/orchestrator.lock/pid   # nonexistent PID
./orchestrator.sh    # should log "stale lock... breaking" and proceed
```

### Task 1.6 — C5: gate next task on previous PR's merge

**File:** `orchestrator.sh` — add a block after `STATE_FILE` is loaded
(around line 51) and modify the auto-merge path (around line 162).

```diff
 echo "plan: $PLAN_FILE  task: $CURRENT/$TOTAL  retries: $RETRIES"

+# Gate on any pending PR from a prior tick
+PENDING=$(jq -r '.pending_pr // empty' "$STATE_FILE")
+if [ -n "$PENDING" ]; then
+  PR_STATE=$(gh pr view "$PENDING" --json state -q .state 2>/dev/null || echo UNKNOWN)
+  case "$PR_STATE" in
+    MERGED)
+      echo "PR #$PENDING merged; clearing pending and advancing"
+      jq 'del(.pending_pr) | .current_task += 1 | .retries_for_current = 0' \
+        "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
+      # Re-load values for this tick now that we've advanced
+      CURRENT=$(jq -r '.current_task' "$STATE_FILE")
+      RETRIES=0
+      ;;
+    CLOSED)
+      echo "PR #$PENDING closed unmerged"
+      bash "$NOTIFY" "PR #$PENDING closed" "plan $PLAN_NUM stuck; investigate"
+      jq '.status = "blocked"' "$STATE_FILE" > "$STATE_FILE.tmp" \
+        && mv "$STATE_FILE.tmp" "$STATE_FILE"
+      exit 1
+      ;;
+    *)
+      echo "waiting on PR #$PENDING (state=$PR_STATE)"
+      exit 0
+      ;;
+  esac
+fi
+
 if [ "$CURRENT" -gt "$TOTAL" ]; then
```

And in the auto-merge branch (around line 162), record pending instead of
advancing:

```diff
-if [ "$AUTO_MERGE" = "true" ]; then
-  gh pr merge "$PR_NUM" --auto --squash --delete-branch 2>&1 \
-    && echo "auto-merge enabled on PR #$PR_NUM" \
-    || echo "warning: --auto failed; PR will need manual merge"
-else
-  ...
-fi
-
-# Advance state
-NEXT=$((CURRENT + 1))
-jq ".current_task = $NEXT | .retries_for_current = 0" "$STATE_FILE" \
-  > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
+if [ "$AUTO_MERGE" = "true" ]; then
+  if gh pr merge "$PR_NUM" --auto --squash --delete-branch 2>&1; then
+    echo "auto-merge enabled on PR #$PR_NUM; will advance after merge"
+    jq --argjson pr "$PR_NUM" '.pending_pr = $pr | .retries_for_current = 0' \
+      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
+  else
+    echo "--auto failed; treating as needs-review"
+    gh pr edit "$PR_NUM" --add-label "needs-robbie" 2>/dev/null || true
+    bash "$NOTIFY" "auto-merge failed" "plan $PLAN_NUM task $CURRENT: $PR_URL"
+    jq ".current_task = $((CURRENT + 1)) | .retries_for_current = 0" \
+      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
+  fi
+else
+  gh pr edit "$PR_NUM" --add-label "needs-robbie" 2>/dev/null || true
+  bash "$NOTIFY" "PR needs review" "plan $PLAN_NUM task $CURRENT: $PR_URL"
+  echo "labeled needs-robbie on PR #$PR_NUM"
+  jq ".current_task = $((CURRENT + 1)) | .retries_for_current = 0" \
+    "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
+fi
```

**Verify:** ingest a 2-task plan; run one tick; confirm `pending_pr` is set
and `current_task` is still 1. Force-merge the PR via `gh`; run another tick;
confirm `pending_pr` cleared and `current_task` is 2.

---

## Phase 2 — Reviewer reliability (land before second smoke run)

### Task 2.1 — H1: track fence state in plan-section awk

**File:** `.claude/hooks/stop-pre-push-review.sh:40-45` and
`.claude/scripts/ingest-plan.sh:66-89`

Add at the top of both awk programs:

```awk
/^```/ { in_fence = !in_fence; print; next }
in_fence { print; next }
```

For ingest-plan.sh (which doesn't print non-task content), use:

```awk
/^```/ { in_fence = !in_fence; next }
in_fence { next }
```

**Verify:** plan with literal `## Task 99: example` inside a fenced code
block — confirm `total_tasks` reflects only real headers.

### Task 2.2 — H2: use `origin/main...HEAD` for the diff

**File:** `.claude/hooks/stop-pre-push-review.sh:53`

```diff
-DIFF=$(git diff main...HEAD 2>/dev/null || git diff HEAD)
+DIFF=$(git diff origin/main...HEAD 2>/dev/null || true)
+[ -z "$DIFF" ] && exit 0
```

Drop the `git diff HEAD` fallback — after the worker commits, it would be
empty and skip review.

**Verify:** worker commits on a branch where local `main` is stale; reviewer
should still see the right diff.

### Task 2.3 — H3: extract first JSON object regardless of fences/prose

**File:** `.claude/hooks/stop-pre-push-review.sh:86-90`

```diff
-REVIEW_TEXT=$(echo "$REVIEW_TEXT" | sed -e 's/^```json//' -e 's/```$//' | tr -d '\r')
-PASS=$(echo "$REVIEW_TEXT" | jq -r '.pass // false' 2>/dev/null || echo "false")
+# Extract first balanced { ... } block, ignoring fences/prose
+REVIEW_JSON=$(printf '%s' "$REVIEW_TEXT" | tr -d '\r' | awk '
+  BEGIN { depth = 0; capture = 0 }
+  {
+    for (i = 1; i <= length($0); i++) {
+      c = substr($0, i, 1)
+      if (c == "{") { depth++; capture = 1 }
+      if (capture) printf "%s", c
+      if (c == "}") { depth--; if (depth == 0 && capture) { print ""; exit } }
+    }
+    if (capture) print ""
+  }
+')
+PASS=$(printf '%s' "$REVIEW_JSON" | jq -r '.pass // false' 2>/dev/null || echo "false")
```

Replace the `BLOCKERS` extraction line below to use `$REVIEW_JSON` instead
of `$REVIEW_TEXT`.

**Verify:** simulate by writing a fake `RESPONSE` that wraps JSON in markdown
fences with leading prose, pipe through the extraction, confirm valid JSON.

---

## Phase 3 — Cost & ergonomics (before second week)

### Task 3.1 — H5: parameterize model and turn budget; lower defaults

**File:** `orchestrator.sh:91-104`

```diff
+MAX_TURNS="${ORCH_MAX_TURNS:-30}"
+WORKER_MODEL="${ORCH_WORKER_MODEL:-sonnet}"
+
 claude -p "$(cat "$WORKER_PROMPT_FILE")
 ...
   --permission-mode acceptEdits \
   --output-format json \
-  --model "opus" \
-  --max-turns 60 \
+  --model "$WORKER_MODEL" \
+  --max-turns "$MAX_TURNS" \
   > "$RUN_OUT"
```

Document escalation: set `ORCH_WORKER_MODEL=opus` for plans known to need it
(e.g., a complex refactor). Or encode model selection in the state file
alongside `auto_merge_overrides`.

### Task 3.2 — H7: document required `permissions.allow` block

**File:** `README.md`

Add a section between "First run" and "What each tick does":

```markdown
## Required permissions allowlist

The worker runs with `--permission-mode acceptEdits`, which only auto-accepts
file edits. Bash commands (tests, commits, gh) still need explicit allowlists,
or the worker stalls. Add to `.claude/settings.json`:

\`\`\`json
{
  "permissions": {
    "allow": [
      "Bash(git add:*)", "Bash(git commit:*)", "Bash(git diff:*)",
      "Bash(git status:*)", "Bash(git log:*)",
      "Bash(pytest:*)", "Bash(uv run:*)", "Bash(pnpm:*)", "Bash(npm test:*)",
      "Bash(gh issue create:*)"
    ]
  },
  "hooks": { ... }
}
\`\`\`

Tighten this list to your project's actual commands.
```

### Task 3.3 — H4: broaden + tighten sensitive patterns

**File:** `.claude/scripts/ingest-plan.sh:40-59`

```diff
 SENSITIVE_PATTERNS=(
-  'IAM' 'iam\.PolicyStatement' 'iam\.Role' 'aws_iam_role'
-  'infra/' 'terraform/prod' 'migrations?/' 'schema\.sql'
-  'PolicyDocument' 'AssumeRole' 'Effect.*Deny' 'Effect.*Allow'
-  'Guardrail' 'Secret' 'KMS' 'security-group' 'SecurityGroup'
-  '\.github/workflows/'
+  '\bIAM\b' '\baws_iam_' 'iam\.PolicyStatement' 'iam\.Role'
+  'PolicyDocument' 'AssumeRole' '"Effect"'
+  'Principal[[:space:]]*[:=][[:space:]]*"\*"'
+  '0\.0\.0\.0/0' 'public_?access' 'PublicAccessBlock'
+  'BucketPolicy' 'FunctionUrl'
+  '\bKMS\b' 'SecretsManager' 'security[_-]group' 'NetworkAcl'
+  'migrations?/' 'schema\.sql' '[Aa]lter [Tt]able' '[Dd]rop [Cc]olumn'
+  '\.github/workflows/' 'terraform/(prod|production)/' '\binfra/'
 )
```

### Task 3.4 — H6: ensure archive directory exists

**File:** `orchestrator.sh:23` (alongside other mkdir)

```diff
 mkdir -p .claude/state
+mkdir -p .claude/plans/archive
```

Drop the `2>/dev/null || true` from the archive `mv` calls — once the dir
exists, you want failures visible.

---

## Phase 4 — Polish (medium, non-blocking)

| ID  | File                              | Change                                                                 |
|-----|-----------------------------------|------------------------------------------------------------------------|
| M1  | `orchestrator.sh`                 | Pre-extract task section, pass inline; reduce per-tick token cost      |
| M2  | `orchestrator.sh:84`              | `RUN_OUT` includes `${RETRIES}` so retries don't overwrite             |
| M3  | `orchestrator.sh:24` + cron       | Log rotation: append-mode + size-based roll, or logrotate config       |
| M4  | `worker-superpower.md`            | Add concrete tier examples + "default to Tier 3 when unclear" backstop |
| M5  | `defaults.md` vs `CLAUDE.md`      | Move codified standards to CLAUDE.md; keep defaults.md as resolution rules only |
| M6  | `notify.sh`                       | Fall through to next channel on curl failure instead of `exit 0`       |
| M7  | sidecar cron                      | Weekly `git worktree prune` to clean abandoned worktrees               |

---

## Soak protocol — when to trust it unattended

1. **Manual smoke (Phase 1 done):** ingest a 2-task plan that only edits a
   README. Run `./orchestrator.sh` manually three times (one tick each).
   Confirm: PR opened, auto-merged, second task starts only after PR merges.
2. **Cron, low-stakes plans (Phase 1+2 done):** schedule cron, but only
   stage plans that touch tests/docs. Watch `orchestrator.log` daily for a
   week. Track Max-plan quota burn.
3. **Cron, code-touching plans (Phase 1+2+3 done):** allow plans that
   modify application code but not infra/migrations.
4. **Full trust (after 2 weeks clean):** allow infra-touching plans, with
   `auto_merge_overrides` honored by the (now working) sensitive-pattern
   detector.

Stop and roll back to a prior phase if you see: any silent state advance, any
reviewer recursion, any commit landing on `main` outside a PR, or quota burn
above 2× expected.

---

## Out of scope for this plan

- New features (Routines, GitLab, parallelism, /autofix-pr) — design first
- Migrating to the Anthropic Agent SDK (requires API keys; Max OAuth only)
- Bash style preferences

---

## Tracking checklist

```
Phase 1 — Safety nets
  [ ] 1.1  C4  gawk required + invoked
  [ ] 1.2  C2  SKIP_REVIEW=1 on reviewer call
  [ ] 1.3  C3  worktree/cd hard-fail
  [ ] 1.4  C6  git push error handling
  [ ] 1.5  C1  PID-aware lockdir
  [ ] 1.6  C5  pending-PR gating

Phase 2 — Reviewer reliability
  [ ] 2.1  H1  fence-aware awk
  [ ] 2.2  H2  origin/main diff base
  [ ] 2.3  H3  robust JSON extraction

Phase 3 — Cost & ergonomics
  [ ] 3.1  H5  configurable model + max-turns
  [ ] 3.2  H7  permissions allowlist documented
  [ ] 3.3  H4  sensitive patterns broadened
  [ ] 3.4  H6  archive dir created

Phase 4 — Polish
  [ ] 4.1  M1  pre-extract task content
  [ ] 4.2  M2  retry-aware RUN_OUT
  [ ] 4.3  M3  log rotation
  [ ] 4.4  M4  decision-tier examples
  [ ] 4.5  M5  defaults vs CLAUDE.md split
  [ ] 4.6  M6  notify fall-through
  [ ] 4.7  M7  worktree prune sidecar
```
