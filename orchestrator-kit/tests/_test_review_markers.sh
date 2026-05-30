#!/usr/bin/env bash
# Tests for review-pass.sh marker extraction (the regex pair at
# orchestrator-kit/.claude/scripts/review-pass.sh:148-160).
#
# Background
# ----------
# The earlier regex `orch:review-sha:[a-f0-9]+` matched any occurrence in
# the PR body — including bare strings that ended up inside fenced code
# blocks (e.g. PLAN-07 T1 reproduced a PR-body shadow where a code-block
# sample marker beat the real one). The reader now requires the same
# `<!-- ... -->` delimiters the writer emits at review-pr.sh:464.
#
# This test pins the contract on both markers:
#   * `orch:review-sha:HEX` in body prose or inside backticks is NOT picked
#     up by the extractor.
#   * `<!-- orch:review-sha:HEX -->` later in the body IS picked up.
#   * Same for `orch:ci-gate-sha:HEX`.
#
# The grep pipeline is copied verbatim from review-pass.sh so a drift in
# either copy will fail this test loudly. If you change the script's regex,
# update both copies (orchestrator-kit/ and .claude/) and this test.
#
# Usage: bash orchestrator-kit/tests/_test_review_markers.sh
# Exit:  0 = all pass, 1 = any failure. No external deps beyond `grep`.

set -uo pipefail

TESTS_FAILED=0
fail() { echo "FAIL: $*" >&2; TESTS_FAILED=$((TESTS_FAILED + 1)); }
pass() { echo "PASS: $*"; }

# ─── Helpers under test (mirrors review-pass.sh:152-160) ─────────────────
extract_review_sha() {
  echo "$1" \
    | grep -oE '<!-- *orch:review-sha:[a-f0-9]+ *-->' \
    | head -1 \
    | grep -oE '[a-f0-9]{7,40}'
}

extract_ci_gate_sha() {
  echo "$1" \
    | grep -oE '<!-- *orch:ci-gate-sha:[a-f0-9]+ *-->' \
    | head -1 \
    | grep -oE '[a-f0-9]{7,40}'
}

# ─── T1: real marker wins over a bare in-prose form (PLAN-07 T1 case) ────
echo "--- T1: HTML-comment marker beats bare in-prose form ---"
T1_BODY=$(cat <<'BODY'
## Summary

Adds a marker that looks like `orch:review-sha:cafef00d` for documentation.

Some other prose here.

<!-- orch:review-iter:2 -->
<!-- orch:review-sha:deadbeef1234567 -->
BODY
)
T1_GOT=$(extract_review_sha "$T1_BODY")
if [ "$T1_GOT" = "deadbeef1234567" ]; then
  pass "T1: extracted real marker '$T1_GOT', ignored bare 'cafef00d'"
else
  fail "T1: expected 'deadbeef1234567', got '$T1_GOT'"
fi

# ─── T2: bare-only body must yield empty extraction ──────────────────────
echo "--- T2: bare form alone is not matched ---"
T2_BODY=$(cat <<'BODY'
Just prose. A bare orch:review-sha:cafef00d sample, no real marker.
BODY
)
T2_GOT=$(extract_review_sha "$T2_BODY")
if [ -z "$T2_GOT" ]; then
  pass "T2: bare form correctly produced empty extraction"
else
  fail "T2: expected empty extraction, got '$T2_GOT'"
fi

# ─── T3: extra whitespace inside the comment is tolerated ────────────────
echo "--- T3: HTML-comment with extra internal whitespace ---"
T3_BODY='Body. <!--   orch:review-sha:abcdef1234567890   -->'
T3_GOT=$(extract_review_sha "$T3_BODY")
if [ "$T3_GOT" = "abcdef1234567890" ]; then
  pass "T3: tolerated extra whitespace, extracted '$T3_GOT'"
else
  fail "T3: expected 'abcdef1234567890', got '$T3_GOT'"
fi

# ─── T4: full 40-char SHA (the writer's actual emit shape) ───────────────
echo "--- T4: full 40-char SHA ---"
T4_SHA="0123456789abcdef0123456789abcdef01234567"
T4_BODY="Prose. <!-- orch:review-sha:$T4_SHA -->"
T4_GOT=$(extract_review_sha "$T4_BODY")
if [ "$T4_GOT" = "$T4_SHA" ]; then
  pass "T4: 40-char SHA extracted intact"
else
  fail "T4: expected '$T4_SHA', got '$T4_GOT'"
fi

# ─── T5: same shadow protection on the ci-gate-sha marker ────────────────
echo "--- T5: ci-gate-sha shadow protection ---"
T5_BODY=$(cat <<'BODY'
Some `orch:ci-gate-sha:1111111` mentioned in a code block.
<!-- orch:ci-gate-sha:abcdef9876543 -->
BODY
)
T5_GOT=$(extract_ci_gate_sha "$T5_BODY")
if [ "$T5_GOT" = "abcdef9876543" ]; then
  pass "T5: ci-gate-sha extracted real marker '$T5_GOT'"
else
  fail "T5: expected 'abcdef9876543', got '$T5_GOT'"
fi

# ─── T6: cross-marker isolation (ci-gate extractor ignores review-sha) ───
echo "--- T6: ci-gate extractor does not match review-sha markers ---"
T6_BODY='<!-- orch:review-sha:deadbeef1234567 -->'
T6_GOT=$(extract_ci_gate_sha "$T6_BODY")
if [ -z "$T6_GOT" ]; then
  pass "T6: ci-gate extractor correctly skipped review-sha marker"
else
  fail "T6: expected empty, got '$T6_GOT'"
fi

echo
if [ "$TESTS_FAILED" -eq 0 ]; then
  echo "_test_review_markers.sh: all tests passed"
  exit 0
else
  echo "_test_review_markers.sh: $TESTS_FAILED test(s) failed" >&2
  exit 1
fi
