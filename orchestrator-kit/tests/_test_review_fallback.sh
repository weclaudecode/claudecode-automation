#!/usr/bin/env bash
# Regression test for fallback_non_json_review in _dispatcher_lib.sh.
#
# Background — PLAN-08 T2 / kit issue #63:
# review-pr.sh used to exit 2 with no marker applied when the reviewer
# returned prose instead of a JSON envelope. review-pass.sh then read
# head_sha != last_reviewed_sha on the next tick and re-spawned the
# reviewer at ~$2.19/run. With the kit's default */5 cadence that is
# ~$26/h until manual intervention.
#
# The fallback installed by this PR (T2) takes the burn rate to zero by
# applying the orch:review-sha:HEAD marker, the orch:review-blocked
# label, and a top-level explanatory comment carrying the reviewer's raw
# prose — then exiting 0.
#
# Mock strategy: a tiny `gh` stub hoisted onto $PATH that logs one line
# per gh invocation (omitting the --body payload to keep the log line-
# delimited) and captures --body payloads to side files indexed by
# invocation count. The function under test only calls `gh pr edit` and
# `gh pr comment`, so assertions against the log + side files fully
# verify the contract.
#
# Scenarios:
#   1. Fresh fallback (PR body has no prior marker) — expect 3 gh calls
#      (body-edit with new marker, add-label orch:review-blocked, post
#      comment carrying reviewer prose); body-edit payload carries the
#      synthetic-blocker comment text patterns required by the spec.
#   2. Idempotent re-run (PR body already has marker for the same SHA) —
#      expect 0 gh calls, function returns 0 and stdout notes the skip.
#   3. Different-SHA re-run (PR body has a marker for a different SHA) —
#      expect 3 gh calls with the prior marker stripped and the new one
#      applied (the body must carry exactly one review-sha marker after
#      the fallback runs).
#
# Runs offline. No real gh, no network, no claude.
#
# Usage: bash orchestrator-kit/tests/_test_review_fallback.sh
# Exit:  0 = all pass, 1 = any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$KIT_ROOT/.claude/scripts/_dispatcher_lib.sh"

TESTS_FAILED=0
TESTS_PASSED=0
fail() { echo "FAIL: $*" >&2; TESTS_FAILED=$((TESTS_FAILED + 1)); }
pass() { echo "PASS: $*"; TESTS_PASSED=$((TESTS_PASSED + 1)); }

TMPROOT=$(mktemp -d /tmp/_test_review_fallback.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT INT TERM

# ─── Mock gh ──────────────────────────────────────────────────────────────────
# The stub:
#   - Filters --body and the arg following it out of the logged argv so each
#     gh call produces exactly one log line (otherwise a multi-line body
#     payload would break wc -l-based call counting).
#   - Writes the --body payload to "$GH_STUB_ARGS_DIR/body-<invocation>" so
#     the test can read the exact body that was passed.
#   - Returns exit code 0 unless GH_STUB_EXIT is set.
GH_STUB_DIR="$TMPROOT/bin"
mkdir -p "$GH_STUB_DIR"
cat > "$GH_STUB_DIR/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
# Stub gh for fallback_non_json_review tests.
LOG_FILE="${GH_STUB_LOG:-/dev/null}"
ARGS_DIR="${GH_STUB_ARGS_DIR:-}"

# Build a filtered argv: drop "--body <value>" pairs so the log stays
# line-delimited (gh comment bodies are multi-line and would otherwise
# break wc -l accounting).
filtered=()
skip_next=0
for arg in "$@"; do
  if [ "$skip_next" = "1" ]; then
    skip_next=0
    continue
  fi
  if [ "$arg" = "--body" ]; then
    filtered+=("$arg")
    skip_next=1
    continue
  fi
  filtered+=("$arg")
done

printf '%s\n' "${filtered[*]}" >> "$LOG_FILE"

# Capture the --body payload (if any) to a per-invocation side file.
if [ -n "$ARGS_DIR" ] && [ -d "$ARGS_DIR" ]; then
  INV=$(wc -l < "$LOG_FILE" | tr -d ' ')
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--body" ]; then
      printf '%s' "$arg" > "$ARGS_DIR/body-$INV"
      break
    fi
    prev="$arg"
  done
fi

exit "${GH_STUB_EXIT:-0}"
GHSCRIPT
chmod +x "$GH_STUB_DIR/gh"

export PATH="$GH_STUB_DIR:$PATH"

# Source the lib AFTER PATH manipulation so any gh calls during sourcing
# (defensive — sourcing should be inert) hit our stub.
# shellcheck source=../.claude/scripts/_dispatcher_lib.sh
source "$LIB"

# ─── Fixture: representative non-JSON reviewer prose ──────────────────────────
# Shape lifted from the PLAN-07 T1 reproduction documented in kit issue
# #63: /security-review-style markdown output with headers, bullets, and
# a "Verdict" section — exactly what the model returns when it ignores
# the JSON-only contract in reviewer-system.md.
REVIEWER_PROSE=$(cat <<'PROSE'
# Security Review

I reviewed the diff for PR #142. Findings below.

## Summary

The change adds X. The implementation is mostly correct but there are
issues worth flagging before merge.

## Findings

### High severity

- **Hardcoded fallback secret**: src/foo.py:42 calls
  `os.environ.get("KEY", "dev-default")`. If KEY is unset in prod the
  request signs with the dev secret and silently succeeds.
- **SQL injection vector**: src/bar.py:88 concatenates user-supplied
  `filter` into the SELECT directly.

### Medium severity

- **Missing request timeout**: src/foo.py:120 calls
  `requests.get(url)` with no timeout — long-tail latency from upstream
  will block worker pool.

## Verdict

Request changes — the high-severity findings above must be addressed
before this can merge.
PROSE
)

# Distinct SHAs so scenario 3 can verify strip + replace.
HEAD_OID_A="deadbeefcafef00d1234567890abcdef12345678"
HEAD_OID_B="0badf00d1234567890abcdef12345678deadbeef"
PR_NUM=142
REPO="test-owner/test-repo"

# ─── Scenario 1: Fresh fallback (PR body has no prior marker) ────────────────
echo "--- 1: fresh fallback applies marker + label + comment ---"

S1_LOG="$TMPROOT/s1.log"
S1_ARGS_DIR="$TMPROOT/s1-args"
mkdir -p "$S1_ARGS_DIR"
: > "$S1_LOG"

PR_BODY_FRESH="This is the PR description.

It carries no orch:review-sha marker yet.
"

GH_STUB_LOG="$S1_LOG" GH_STUB_ARGS_DIR="$S1_ARGS_DIR" \
  fallback_non_json_review "$REPO" "$PR_NUM" "$HEAD_OID_A" "$PR_BODY_FRESH" "$REVIEWER_PROSE" \
  > "$TMPROOT/s1.stdout" 2> "$TMPROOT/s1.stderr"
RC=$?

if [ "$RC" = "0" ]; then
  pass "scenario 1: function returns 0"
else
  fail "scenario 1: function returned $RC (expected 0); stderr: $(cat "$TMPROOT/s1.stderr")"
fi

CALL_COUNT=$(wc -l < "$S1_LOG" | tr -d ' ')
if [ "$CALL_COUNT" = "3" ]; then
  pass "scenario 1: exactly 3 gh calls (body-edit, label-add, comment)"
else
  fail "scenario 1: expected 3 gh calls, got $CALL_COUNT — log:
$(cat "$S1_LOG")"
fi

if grep -qE "^pr edit ${PR_NUM} --repo ${REPO} --body$" "$S1_LOG"; then
  pass "scenario 1: pr edit --body call present"
else
  fail "scenario 1: no pr edit --body call in log:
$(cat "$S1_LOG")"
fi

if grep -qE "^pr edit ${PR_NUM} --repo ${REPO} --add-label orch:review-blocked$" "$S1_LOG"; then
  pass "scenario 1: pr edit --add-label orch:review-blocked call present"
else
  fail "scenario 1: no pr edit --add-label call in log:
$(cat "$S1_LOG")"
fi

if grep -qE "^pr comment ${PR_NUM} --repo ${REPO} --body$" "$S1_LOG"; then
  pass "scenario 1: pr comment --body call present"
else
  fail "scenario 1: no pr comment --body call in log:
$(cat "$S1_LOG")"
fi

# Call 1 (body-edit) payload must carry the new marker.
BODY_1="$S1_ARGS_DIR/body-1"
if [ -f "$BODY_1" ] && grep -q "<!-- orch:review-sha:${HEAD_OID_A} -->" "$BODY_1"; then
  pass "scenario 1: body-edit payload contains the new <!-- orch:review-sha:HEAD --> marker"
else
  fail "scenario 1: body-edit payload missing the new marker — body content:
$(cat "$BODY_1" 2>/dev/null || echo '(no body file)')"
fi

# Exactly one marker, not stacked.
MARKER_COUNT=0
[ -f "$BODY_1" ] && MARKER_COUNT=$(grep -c "<!-- orch:review-sha:" "$BODY_1" 2>/dev/null || echo 0)
if [ "$MARKER_COUNT" = "1" ]; then
  pass "scenario 1: body carries exactly one review-sha marker"
else
  fail "scenario 1: expected exactly 1 marker in body, found $MARKER_COUNT"
fi

# Call 3 (comment) payload must include the synthetic-blocker header AND
# embed the reviewer's raw prose (head -40).
BODY_3="$S1_ARGS_DIR/body-3"
if [ -f "$BODY_3" ] && grep -q "Reviewer produced non-JSON output" "$BODY_3"; then
  pass "scenario 1: comment payload includes synthetic-blocker header"
else
  fail "scenario 1: comment payload missing synthetic-blocker header — content:
$(cat "$BODY_3" 2>/dev/null || echo '(no body file)')"
fi

if [ -f "$BODY_3" ] && grep -q "Security Review" "$BODY_3"; then
  pass "scenario 1: comment payload embeds the reviewer's raw prose"
else
  fail "scenario 1: comment payload missing reviewer prose"
fi

if [ -f "$BODY_3" ] && grep -q "orch:review-blocked" "$BODY_3"; then
  pass "scenario 1: comment payload tells operator how to clear the block"
else
  fail "scenario 1: comment payload missing operator-action instructions"
fi

# ─── Scenario 2: Idempotent re-run (marker for this SHA already present) ─────
echo "--- 2: idempotent re-run — no gh calls when marker already present ---"

S2_LOG="$TMPROOT/s2.log"
S2_ARGS_DIR="$TMPROOT/s2-args"
mkdir -p "$S2_ARGS_DIR"
: > "$S2_LOG"

PR_BODY_WITH_MARKER="This is the PR description.

<!-- orch:review-sha:${HEAD_OID_A} -->
"

GH_STUB_LOG="$S2_LOG" GH_STUB_ARGS_DIR="$S2_ARGS_DIR" \
  fallback_non_json_review "$REPO" "$PR_NUM" "$HEAD_OID_A" "$PR_BODY_WITH_MARKER" "$REVIEWER_PROSE" \
  > "$TMPROOT/s2.stdout" 2> "$TMPROOT/s2.stderr"
RC=$?

if [ "$RC" = "0" ]; then
  pass "scenario 2: function returns 0 (idempotent skip)"
else
  fail "scenario 2: function returned $RC (expected 0); stderr: $(cat "$TMPROOT/s2.stderr")"
fi

CALL_COUNT=$(wc -l < "$S2_LOG" | tr -d ' ')
if [ "$CALL_COUNT" = "0" ]; then
  pass "scenario 2: no gh calls (idempotent skip)"
else
  fail "scenario 2: expected 0 gh calls, got $CALL_COUNT — log:
$(cat "$S2_LOG")"
fi

if grep -q "already on PR" "$TMPROOT/s2.stdout"; then
  pass "scenario 2: stdout notes the idempotent skip"
else
  fail "scenario 2: stdout missing skip-acknowledgement — content:
$(cat "$TMPROOT/s2.stdout")"
fi

# ─── Scenario 3: Different-SHA fallback strips prior marker, applies new ─────
echo "--- 3: different-SHA fallback strips prior marker, applies new ---"

S3_LOG="$TMPROOT/s3.log"
S3_ARGS_DIR="$TMPROOT/s3-args"
mkdir -p "$S3_ARGS_DIR"
: > "$S3_LOG"

PR_BODY_OLD_MARKER="This is the PR description.

<!-- orch:review-sha:${HEAD_OID_A} -->
"

GH_STUB_LOG="$S3_LOG" GH_STUB_ARGS_DIR="$S3_ARGS_DIR" \
  fallback_non_json_review "$REPO" "$PR_NUM" "$HEAD_OID_B" "$PR_BODY_OLD_MARKER" "$REVIEWER_PROSE" \
  > "$TMPROOT/s3.stdout" 2> "$TMPROOT/s3.stderr"
RC=$?

if [ "$RC" = "0" ]; then
  pass "scenario 3: function returns 0"
else
  fail "scenario 3: function returned $RC (expected 0); stderr: $(cat "$TMPROOT/s3.stderr")"
fi

CALL_COUNT=$(wc -l < "$S3_LOG" | tr -d ' ')
if [ "$CALL_COUNT" = "3" ]; then
  pass "scenario 3: exactly 3 gh calls (different SHA → not idempotent skip)"
else
  fail "scenario 3: expected 3 gh calls, got $CALL_COUNT — log:
$(cat "$S3_LOG")"
fi

BODY_1="$S3_ARGS_DIR/body-1"
if [ -f "$BODY_1" ] && grep -q "<!-- orch:review-sha:${HEAD_OID_B} -->" "$BODY_1"; then
  pass "scenario 3: body-edit payload has new HEAD_OID_B marker"
else
  fail "scenario 3: body-edit payload missing new marker — content:
$(cat "$BODY_1" 2>/dev/null || echo '(no body file)')"
fi

if [ -f "$BODY_1" ] && grep -q "<!-- orch:review-sha:${HEAD_OID_A} -->" "$BODY_1"; then
  fail "scenario 3: old HEAD_OID_A marker should have been stripped — content:
$(cat "$BODY_1")"
else
  pass "scenario 3: old HEAD_OID_A marker was stripped"
fi

MARKER_COUNT=0
[ -f "$BODY_1" ] && MARKER_COUNT=$(grep -c "<!-- orch:review-sha:" "$BODY_1" 2>/dev/null || echo 0)
if [ "$MARKER_COUNT" = "1" ]; then
  pass "scenario 3: body carries exactly one review-sha marker"
else
  fail "scenario 3: expected exactly 1 marker in body, found $MARKER_COUNT"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [ "$TESTS_FAILED" -gt 0 ]; then
  echo "RESULT: $TESTS_FAILED/$TOTAL assertion(s) failed" >&2
  exit 1
fi
echo "RESULT: $TESTS_PASSED/$TOTAL assertions passed"
exit 0
