#!/usr/bin/env bash
# Tests for ingest-plan.sh covering recently-added behavior:
#
#   A. Per-task `acceptance:` field — parsed into state.tasks.N.acceptance.
#      Commas inside criteria preserved; absent field = no key in state;
#      empty array = no key (matches jq guard `length > 0`).
#
#   B. Frontmatter unknown-key gate — ingest exits 1 with a clear error
#      when the plan's YAML frontmatter contains a key outside ALLOWED_KEYS.
#      The PLAN-FORMAT.md doc claim depended on this; the test pins the
#      behavior so the gate cannot silently regress.
#
# Approach: build minimal valid plans in tmpdir, invoke ingest-plan.sh,
# then jq the resulting state.json (or assert exit code + stderr for the
# negative cases). No gh/network/claude dependencies.
#
# Usage: bash orchestrator-kit/tests/_test_ingest_plan.sh
# Exit:  0 = all pass, 1 = any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INGEST="$KIT_ROOT/.claude/scripts/ingest-plan.sh"

TESTS_FAILED=0
fail() { echo "FAIL: $*" >&2; TESTS_FAILED=$((TESTS_FAILED + 1)); }
pass() { echo "PASS: $*"; }

# Each test runs in its own tmpdir so state files don't collide.
make_tmpdir() { mktemp -d "/tmp/_test_ingest_plan.XXXXXX"; }

# Write the smallest valid plan body (one task, no deps, single touch) and
# prefix it with whatever frontmatter / extra task lines the caller supplies.
# Args: <tmpdir> <plan_basename_without_ext> <frontmatter_block> <extra_task_lines>
write_plan() {
  local dir="$1" base="$2" frontmatter="$3" extra="$4"
  local file="$dir/${base}.md"
  {
    if [ -n "$frontmatter" ]; then
      printf '%s\n' "$frontmatter"
    fi
    cat <<EOF
# ${base} — fixture

Body prose.

## Task 1: A simple task
**depends_on:** []
**touches:** [\`src/x.py\`]
${extra}
Body of task 1.
EOF
  } > "$file"
  echo "$file"
}

# ─── A1. acceptance: present with multiple criteria, one containing a comma ───
echo "--- A1: acceptance with comma-bearing criterion ---"
A1_DIR=$(make_tmpdir)
A1_PLAN=$(write_plan "$A1_DIR" "PLAN-91-accept-multi" "" \
  '**acceptance:** [`returns 200 on valid body`, `rejects empty body, 400`, `unit tests cover both paths`]')
if "$INGEST" "$A1_PLAN" >/dev/null 2>"$A1_DIR/stderr"; then
  STATE="$A1_DIR/PLAN-91-accept-multi.state.json"
  GOT=$(jq -c '.tasks["1"].acceptance' "$STATE")
  WANT='["returns 200 on valid body","rejects empty body, 400","unit tests cover both paths"]'
  if [ "$GOT" = "$WANT" ]; then
    pass "acceptance array: $GOT"
  else
    fail "acceptance array mismatch. got=$GOT want=$WANT"
  fi
else
  fail "ingest exited non-zero on valid plan: $(cat "$A1_DIR/stderr")"
fi
rm -rf "$A1_DIR"

# ─── A2. acceptance: absent → field must NOT appear in state ──────────────────
echo "--- A2: acceptance absent (backward-compat) ---"
A2_DIR=$(make_tmpdir)
A2_PLAN=$(write_plan "$A2_DIR" "PLAN-92-no-accept" "" "")
if "$INGEST" "$A2_PLAN" >/dev/null 2>"$A2_DIR/stderr"; then
  STATE="$A2_DIR/PLAN-92-no-accept.state.json"
  HAS=$(jq '.tasks["1"] | has("acceptance")' "$STATE")
  if [ "$HAS" = "false" ]; then
    pass "no acceptance key on task without acceptance:"
  else
    fail "acceptance key unexpectedly present on task without acceptance:"
  fi
else
  fail "ingest exited non-zero: $(cat "$A2_DIR/stderr")"
fi
rm -rf "$A2_DIR"

# ─── A3. acceptance: [] (empty array) → field must NOT appear in state ────────
# Matches the jq guard in ingest-plan.sh: `length > 0` filters empty arrays.
# Without this, downstream `(.acceptance // []) | if length > 0 then …` checks
# in launch-worker.sh / review-pr.sh would emit an empty "Acceptance criteria"
# header with no items — visible noise on every task.
echo "--- A3: acceptance: [] omitted from state ---"
A3_DIR=$(make_tmpdir)
A3_PLAN=$(write_plan "$A3_DIR" "PLAN-93-empty-accept" "" '**acceptance:** []')
if "$INGEST" "$A3_PLAN" >/dev/null 2>"$A3_DIR/stderr"; then
  STATE="$A3_DIR/PLAN-93-empty-accept.state.json"
  HAS=$(jq '.tasks["1"] | has("acceptance")' "$STATE")
  if [ "$HAS" = "false" ]; then
    pass "empty acceptance: [] correctly omitted from state"
  else
    fail "empty acceptance: [] left a key in state (would surface as empty header in prompts)"
  fi
else
  fail "ingest exited non-zero on empty-array plan: $(cat "$A3_DIR/stderr")"
fi
rm -rf "$A3_DIR"

# ─── B1. Frontmatter gate: unknown top-level key rejected ─────────────────────
# Pins the doc claim from PLAN-FORMAT.md. Reason for the test: a prior
# silent-acceptance bug class on this kit (cf. project_kit_safety_findings)
# motivated the ALLOWED_KEYS gate; a regression would silently no-op the
# typo'd field instead of erroring at ingest.
echo "--- B1: typo'd top-level frontmatter key rejected ---"
B1_DIR=$(make_tmpdir)
B1_FM='---
env: dev
awss:
  account: "123456789012"
  region: us-east-1
  profile: r
  cdk_app_path: infra
---'
B1_PLAN=$(write_plan "$B1_DIR" "PLAN-94-typo-key" "$B1_FM" "")
if "$INGEST" "$B1_PLAN" >/dev/null 2>"$B1_DIR/stderr"; then
  fail "ingest accepted plan with unknown frontmatter key 'awss' (expected exit 1)"
else
  if grep -q "unknown frontmatter key 'awss'" "$B1_DIR/stderr"; then
    pass "unknown key 'awss' rejected with clear error"
  else
    fail "rejected but stderr did not name the offending key. stderr=$(cat "$B1_DIR/stderr")"
  fi
fi
rm -rf "$B1_DIR"

# ─── B2. Frontmatter gate: known-keys-only ingest succeeds ────────────────────
echo "--- B2: all-known-keys frontmatter accepted ---"
B2_DIR=$(make_tmpdir)
B2_FM='---
env: staging
auto_recommended: false
---'
B2_PLAN=$(write_plan "$B2_DIR" "PLAN-95-known-only" "$B2_FM" "")
if "$INGEST" "$B2_PLAN" >/dev/null 2>"$B2_DIR/stderr"; then
  STATE="$B2_DIR/PLAN-95-known-only.state.json"
  ENV_GOT=$(jq -r '.env // ""' "$STATE")
  if [ "$ENV_GOT" = "staging" ]; then
    pass "known-only frontmatter (env=staging) ingested"
  else
    fail "ingest succeeded but env not set in state. got=$ENV_GOT"
  fi
else
  fail "ingest rejected plan with only known keys: $(cat "$B2_DIR/stderr")"
fi
rm -rf "$B2_DIR"

# ─── B3. Frontmatter gate: empty frontmatter block accepted ───────────────────
# `---\n---\n` is a valid YAML "null document"; the gate must treat it as
# "no frontmatter" rather than erroring out.
echo "--- B3: empty frontmatter block accepted ---"
B3_DIR=$(make_tmpdir)
B3_FM='---
---'
B3_PLAN=$(write_plan "$B3_DIR" "PLAN-96-empty-fm" "$B3_FM" "")
if "$INGEST" "$B3_PLAN" >/dev/null 2>"$B3_DIR/stderr"; then
  pass "empty frontmatter block accepted"
else
  fail "ingest rejected plan with empty '---\\n---' frontmatter: $(cat "$B3_DIR/stderr")"
fi
rm -rf "$B3_DIR"

# ─── C. Touches-collision warning: 2+ tasks share a path → advisory message ──
# Pins the contract added with PLAN-10 Task 2: ingest emits a stderr warning
# for every path listed by ≥2 tasks (the runtime collision detector would
# serialize them anyway), and exits 0 because the warning is advisory.
make_multitask_plan() {
  # Args: <dir> <basename> <task2_touches>
  # Always emits Task 1 with touches=[`src/x.py`]; Task 2's touches are arg 3.
  local dir="$1" base="$2" t2_touches="$3"
  local file="$dir/${base}.md"
  cat > "$file" <<EOF
# ${base} — fixture

## Task 1: First task
**depends_on:** []
**touches:** [\`src/x.py\`]

Body 1.

## Task 2: Second task
**depends_on:** []
**touches:** ${t2_touches}

Body 2.
EOF
  echo "$file"
}

# ─── C1. Two tasks sharing one path → exactly one warning naming both tasks ──
echo "--- C1: 2 tasks share 1 path → single warning with both task numbers ---"
C1_DIR=$(make_tmpdir)
C1_PLAN=$(make_multitask_plan "$C1_DIR" "PLAN-97-collide-2" '[`src/x.py`]')
if "$INGEST" "$C1_PLAN" >/dev/null 2>"$C1_DIR/stderr"; then
  COUNT=$(grep -c 'tasks share touches path src/x.py' "$C1_DIR/stderr" || true)
  if [ "$COUNT" = "1" ] && grep -q 'tasks: 1, 2' "$C1_DIR/stderr"; then
    pass "single warning emitted naming tasks 1 and 2"
  else
    fail "expected one warning naming both tasks; got count=$COUNT stderr=$(cat "$C1_DIR/stderr")"
  fi
else
  fail "ingest exited non-zero (warning should not block): $(cat "$C1_DIR/stderr")"
fi
rm -rf "$C1_DIR"

# ─── C2. No shared paths → no collision warning emitted ─────────────────────
echo "--- C2: disjoint touches → no collision warning ---"
C2_DIR=$(make_tmpdir)
C2_PLAN=$(make_multitask_plan "$C2_DIR" "PLAN-98-disjoint" '[`src/y.py`]')
if "$INGEST" "$C2_PLAN" >/dev/null 2>"$C2_DIR/stderr"; then
  if grep -q 'tasks share touches path' "$C2_DIR/stderr"; then
    fail "unexpected collision warning on disjoint touches: $(cat "$C2_DIR/stderr")"
  else
    pass "no collision warning on disjoint touches"
  fi
else
  fail "ingest exited non-zero: $(cat "$C2_DIR/stderr")"
fi
rm -rf "$C2_DIR"

# ─── C3. Four tasks sharing one path → single warning listing all four ──────
# Guards against a regression where ≥3 colliding tasks would print N-1
# warnings (one per pair) instead of one consolidated message.
echo "--- C3: 4 tasks share 1 path → single warning listing all four ---"
C3_DIR=$(make_tmpdir)
C3_PLAN="$C3_DIR/PLAN-99-collide-4.md"
cat > "$C3_PLAN" <<'EOF'
# PLAN-99-collide-4 — fixture

## Task 1: a
**depends_on:** []
**touches:** [`shared.py`]

## Task 2: b
**depends_on:** []
**touches:** [`shared.py`]

## Task 3: c
**depends_on:** []
**touches:** [`shared.py`]

## Task 4: d
**depends_on:** []
**touches:** [`shared.py`]
EOF
if "$INGEST" "$C3_PLAN" >/dev/null 2>"$C3_DIR/stderr"; then
  COUNT=$(grep -c 'tasks share touches path shared.py' "$C3_DIR/stderr" || true)
  if [ "$COUNT" = "1" ] && grep -q 'tasks: 1, 2, 3, 4' "$C3_DIR/stderr" && grep -q '^ingest-plan: warning: 4 tasks share' "$C3_DIR/stderr"; then
    pass "single consolidated warning for 4-way collision"
  else
    fail "expected one warning listing 1,2,3,4; got count=$COUNT stderr=$(cat "$C3_DIR/stderr")"
  fi
else
  fail "ingest exited non-zero on 4-way collision: $(cat "$C3_DIR/stderr")"
fi
rm -rf "$C3_DIR"

# ─── Summary ──────────────────────────────────────────────────────────────────
if [ "$TESTS_FAILED" -gt 0 ]; then
  echo "RESULT: $TESTS_FAILED failure(s)" >&2
  exit 1
fi
echo "RESULT: all ingest tests passed"
exit 0
