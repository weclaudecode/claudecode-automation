#!/usr/bin/env bash
# Test: agentcore-bundle skill format and D1-D9 coverage.
#
# Usage: bash orchestrator-kit/tests/_test_agentcore_bundle.sh
#
# Checks:
#   A1. SKILL.md has valid frontmatter (name, description, allowed-tools).
#   A2. SKILL.md references all defect codes D1 through D9.
#
# Exit code: 0 = all pass, 1 = any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_FILE="$KIT_ROOT/.claude/skills/agentcore-bundle/SKILL.md"

TESTS_FAILED=0
fail() { echo "FAIL: $*" >&2; TESTS_FAILED=$((TESTS_FAILED + 1)); }
pass() { echo "PASS: $*"; }

# ---------------------------------------------------------------------------
# A1. SKILL.md exists and has required frontmatter fields
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_FILE" ]; then
  fail "A1: SKILL.md not found at $SKILL_FILE"
else
  FIRST_LINE=$(head -1 "$SKILL_FILE")
  if [ "$FIRST_LINE" != "---" ]; then
    fail "A1: SKILL.md does not start with frontmatter (---)"
  else
    HAS_NAME=$(grep -c '^name: agentcore-bundle' "$SKILL_FILE" || true)
    HAS_DESC=$(grep -c '^description:' "$SKILL_FILE" || true)
    HAS_TOOLS=$(grep -c '^allowed-tools:' "$SKILL_FILE" || true)
    [ "$HAS_NAME" -ge 1 ] || fail "A1: SKILL.md missing 'name: agentcore-bundle'"
    [ "$HAS_DESC" -ge 1 ] || fail "A1: SKILL.md missing 'description:'"
    [ "$HAS_TOOLS" -ge 1 ] || fail "A1: SKILL.md missing 'allowed-tools:'"
    pass "A1: SKILL.md frontmatter has name, description, allowed-tools"
  fi
fi

# ---------------------------------------------------------------------------
# A2. SKILL.md references defect codes D1 through D9
# ---------------------------------------------------------------------------
if [ -f "$SKILL_FILE" ]; then
  ALL_FOUND=1
  for N in 1 2 3 4 5 6 7 8 9; do
    # Accept "D1:", "### D1:", "D1 ", "(D1)" etc.
    if grep -qE "D${N}[^0-9]" "$SKILL_FILE"; then
      pass "A2: D${N} referenced in SKILL.md"
    else
      fail "A2: D${N} not found in SKILL.md"
      ALL_FOUND=0
    fi
  done
  [ "$ALL_FOUND" -eq 1 ] && pass "A2: all D1-D9 present"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [ "$TESTS_FAILED" -eq 0 ]; then
  echo "All automated checks passed."
  exit 0
else
  echo "$TESTS_FAILED test(s) failed."
  exit 1
fi
