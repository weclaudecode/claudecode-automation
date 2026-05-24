#!/usr/bin/env bash
# Test runner for the agent-manifest-to-plan skill.
#
# Usage: bash orchestrator-kit/tests/_test_manifest_to_plan.sh
#
# Test coverage strategy:
#   The skill's plan-generation logic is Claude-driven prose execution —
#   there is no extractable shell or Python helper to unit-test in isolation.
#   This script therefore covers two categories:
#
#   Category A — Format checks (automated, run here):
#     1. SKILL.md has valid frontmatter (name + description + allowed-tools).
#     2. Slash command file parses: has frontmatter with name/description, and a body.
#     3. Fixture YAML exists and is well-formed (python3 yaml.safe_load).
#     4. A hand-authored reference plan generated from the fixture passes
#        ingest-plan.sh — this validates the PLAN-FORMAT rules embedded in
#        the skill instructions.
#
#   Category B — Live session test (manual, not run here):
#     Run: /agent-manifest-to-plan orchestrator-kit/docs/fixtures/agent-manifest-xero-fixture.yaml
#     in a Claude Code session at a kit-installed repo. Confirm ingest-plan.sh
#     accepts the output without manual edits.
#
# Exit code: 0 = all pass, 1 = any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SKILL_FILE="$KIT_ROOT/.claude/skills/agent-manifest-to-plan/SKILL.md"
COMMAND_FILE="$KIT_ROOT/.claude/commands/agent-manifest-to-plan.md"
FIXTURE_YAML="$KIT_ROOT/docs/fixtures/agent-manifest-xero-fixture.yaml"
INGEST_SCRIPT="$KIT_ROOT/.claude/scripts/ingest-plan.sh"

TESTS_FAILED=0
fail() { echo "FAIL: $*" >&2; TESTS_FAILED=$((TESTS_FAILED + 1)); }
pass() { echo "PASS: $*"; }
skip() { echo "SKIP: $*"; }

# ---------------------------------------------------------------------------
# A1. SKILL.md exists and has required frontmatter fields
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_FILE" ]; then
  fail "A1: SKILL.md not found at $SKILL_FILE"
else
  # Check frontmatter starts at line 1
  FIRST_LINE=$(head -1 "$SKILL_FILE")
  if [ "$FIRST_LINE" != "---" ]; then
    fail "A1: SKILL.md does not start with frontmatter (---)"
  else
    HAS_NAME=$(grep -c '^name: agent-manifest-to-plan' "$SKILL_FILE" || true)
    HAS_DESC=$(grep -c '^description:' "$SKILL_FILE" || true)
    HAS_TOOLS=$(grep -c '^allowed-tools:' "$SKILL_FILE" || true)
    [ "$HAS_NAME" -ge 1 ] || fail "A1: SKILL.md missing 'name: agent-manifest-to-plan'"
    [ "$HAS_DESC" -ge 1 ] || fail "A1: SKILL.md missing 'description:'"
    [ "$HAS_TOOLS" -ge 1 ] || fail "A1: SKILL.md missing 'allowed-tools:'"
    pass "A1: SKILL.md frontmatter has name, description, allowed-tools"
  fi
fi

# ---------------------------------------------------------------------------
# A2. Slash command file exists and has required frontmatter fields
# ---------------------------------------------------------------------------
if [ ! -f "$COMMAND_FILE" ]; then
  fail "A2: command file not found at $COMMAND_FILE"
else
  FIRST_LINE=$(head -1 "$COMMAND_FILE")
  if [ "$FIRST_LINE" != "---" ]; then
    fail "A2: command file does not start with frontmatter (---)"
  else
    HAS_NAME=$(grep -c '^name: agent-manifest-to-plan' "$COMMAND_FILE" || true)
    HAS_DESC=$(grep -c '^description:' "$COMMAND_FILE" || true)
    HAS_ARG=$(grep -c '^argument-hint:' "$COMMAND_FILE" || true)
    [ "$HAS_NAME" -ge 1 ] || fail "A2: command file missing 'name: agent-manifest-to-plan'"
    [ "$HAS_DESC" -ge 1 ] || fail "A2: command file missing 'description:'"
    [ "$HAS_ARG" -ge 1 ] || fail "A2: command file missing 'argument-hint:'"
    pass "A2: command file frontmatter has name, description, argument-hint"
  fi
fi

# ---------------------------------------------------------------------------
# A3. Fixture YAML exists and is well-formed
# ---------------------------------------------------------------------------
if [ ! -f "$FIXTURE_YAML" ]; then
  fail "A3: fixture not found at $FIXTURE_YAML"
elif ! command -v python3 >/dev/null 2>&1; then
  skip "A3: python3 not available — cannot validate fixture YAML"
else
  ERR=$(python3 -c "
import sys, yaml
with open('$FIXTURE_YAML') as f:
    data = yaml.safe_load(f)
tools = data.get('tools', [])
active = [t for t in tools if t.get('status', 'active') != 'deferred']
deferred = [t for t in tools if t.get('status') == 'deferred']
print(f'active={len(active)} deferred={len(deferred)}')
# Assertions
assert 'name' in data or 'agent' in data, 'no agent name field'
assert len(active) >= 1, 'no active tools'
assert len(deferred) >= 1, 'no deferred tools (fixture should exercise deferred path)'
" 2>&1)
  RC=$?
  if [ $RC -ne 0 ]; then
    fail "A3: fixture YAML invalid: $ERR"
  else
    pass "A3: fixture YAML valid — $ERR"
  fi
fi

# ---------------------------------------------------------------------------
# A4. Reference plan generated from the fixture passes ingest-plan.sh
#     We hand-author a plan matching what the skill would produce for the
#     fixture (2 active tools → 4 tasks: toolbelt + 2 per-tool + deploy).
#     This validates the PLAN-FORMAT rules embedded in the skill instructions.
# ---------------------------------------------------------------------------

if ! command -v gawk >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  skip "A4: gawk/jq/python3 not all available — skipping ingest validation"
elif [ ! -f "$INGEST_SCRIPT" ]; then
  skip "A4: ingest-plan.sh not found at $INGEST_SCRIPT"
else
  TMPDIR_A4=$(mktemp -d /tmp/_test_manifest_to_plan.XXXXXX)
  PLANS_DIR="$TMPDIR_A4/.claude/plans"
  mkdir -p "$PLANS_DIR"

  REF_PLAN="$PLANS_DIR/PLAN-99-test-agent-tools.md"
  cat > "$REF_PLAN" <<'EOF'
---
env: dev
aws:
  account: "111122223333"
  region: ap-southeast-2
  profile: test-profile
  cdk_app_path: infrastructure
---

# PLAN-99-test-agent-tools — implement 2 agent tools for test-agent

This plan implements the 2 active Lambda tools declared in the test-agent
manifest, plus the shared toolbelt module they depend on. Each tool gets
its own Lambda function and Gateway target. The final task re-enables any
deferred tools in the manifest and deploys the GatewayStack.
1 tool was skipped (status: deferred): tool-deferred.

## Task 1: Shared toolbelt module
**depends_on:** []
**touches:** [`agents/test-agent/tools/_shared/**`]

Create the shared toolbelt at `agents/test-agent/tools/_shared/`:
- `xero_client.py` — client wrapping token resolution, retry/backoff.
- `gateway_context.py` — `parse_context(event) -> Context`.
- `supabase.py` — `audit_start`, `audit_finish`, `persist_snapshot`.
- `normalise.py` — normaliser functions per report type.
- `errors.py` — `ToolError` and related exceptions.

Write unit tests in `agents/test-agent/tools/_shared/test_shared.py`.
Commit: `feat: add test-agent shared toolbelt module`.

## Task 2: Tool tool-one — Lambda + schema
**depends_on:** [1]
**touches:** [`agents/test-agent/tools/tool_one/**`]

Implement the `tool-one` tool Lambda at `agents/test-agent/tools/tool_one/`:
- `index.py` — handler using the shared toolbelt.
- `schema.json` — MCP tool schema.
- `requirements.txt` — tool-specific dependencies.
- `test_handler.py` — unit test with stubbed responses.

First active tool for testing.
Auth: iam
Commit: `feat: implement tool-one Lambda tool`.

## Task 3: Tool tool-two — Lambda + schema
**depends_on:** [1]
**touches:** [`agents/test-agent/tools/tool_two/**`]

Implement the `tool-two` tool Lambda at `agents/test-agent/tools/tool_two/`:
- `index.py` — handler using the shared toolbelt.
- `schema.json` — MCP tool schema.
- `requirements.txt` — tool-specific dependencies.
- `test_handler.py` — unit test with stubbed responses.

Second active tool for testing.
Auth: oauth_3lo
Commit: `feat: implement tool-two Lambda tool`.

## Task 4: Re-enable tools in manifest and deploy GatewayStack
**depends_on:** [2, 3]
**touches:** [`infrastructure/config/agents/**`, `infrastructure/stacks/**`]
**auto_merge:** false

1. Remove any `status: deferred` lines from the manifest so all 2 tools are active.
2. Run `python scripts/validate_manifests.py` — must exit 0.
3. Deploy: `cd infrastructure && cdk deploy GatewayStack-test-agent`.
4. Verify via AWS CLI that 2 Lambda functions and 2 Gateway targets exist.

Commit: `feat(infra): deploy test-agent GatewayStack with all 2 tools`.
EOF

  INGEST_OUT=$(bash "$INGEST_SCRIPT" "$REF_PLAN" 2>&1)
  RC=$?
  if [ $RC -ne 0 ]; then
    fail "A4: reference plan failed ingest-plan.sh:\n$INGEST_OUT"
  else
    # Verify state.json sanity
    STATE_FILE="$PLANS_DIR/PLAN-99-test-agent-tools.state.json"
    if [ ! -f "$STATE_FILE" ]; then
      fail "A4: state.json not written despite ingest exit 0"
    else
      TOTAL=$(jq '.total_tasks' "$STATE_FILE")
      AMO=$(jq '.auto_merge_overrides | keys | length' "$STATE_FILE")
      if [ "$TOTAL" = "4" ] && [ "$AMO" = "1" ]; then
        pass "A4: reference plan ingested cleanly — total_tasks=$TOTAL auto_merge_overrides keys=$AMO"
      else
        fail "A4: unexpected state.json — total_tasks=$TOTAL (want 4), auto_merge_overrides keys=$AMO (want 1)"
      fi
    fi
  fi

  rm -rf "$TMPDIR_A4"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [ "$TESTS_FAILED" -eq 0 ]; then
  echo "All automated checks passed."
  echo ""
  echo "Manual live-session test (Category B):"
  echo "  1. Install the kit into a test repo (see orchestrator-kit/README.md)."
  echo "  2. In a Claude Code session at that repo, run:"
  echo "     /agent-manifest-to-plan orchestrator-kit/docs/fixtures/agent-manifest-xero-fixture.yaml"
  echo "  3. Confirm Claude presents the decomposition (2 active tools, 1 deferred)."
  echo "  4. Confirm it writes PLAN-NN-test-agent-tools.md and ingest-plan.sh exits 0."
  exit 0
else
  echo "$TESTS_FAILED test(s) failed."
  exit 1
fi
