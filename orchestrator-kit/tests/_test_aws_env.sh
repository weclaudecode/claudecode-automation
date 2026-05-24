#!/usr/bin/env bash
# Smoke test: verify launch-worker.sh exports AWS env vars from state.aws_env.
#
# Usage: bash orchestrator-kit/tests/_test_aws_env.sh
#
# Two scenarios exercised:
#   1. State WITH aws_env — asserts all five vars are exported to the worker.
#   2. State WITHOUT aws_env — asserts none of the five vars are set.
#
# This test does NOT actually invoke claude -p. It replaces the RUN_CMD
# execution block with an env-dump shim so the env can be inspected without
# a real worker context or API key.
#
# Exit code: 0 = pass, 1 = any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS_DIR="$KIT_ROOT/.claude/scripts"

TESTS_FAILED=0

fail() { echo "FAIL: $*" >&2; TESTS_FAILED=$((TESTS_FAILED + 1)); }
pass() { echo "PASS: $*"; }

# ---------------------------------------------------------------------------
# Build a minimal fake state.json for test scenario $1 ("with_aws"|"no_aws")
# ---------------------------------------------------------------------------
make_state() {
  local variant="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  local state_file="$tmpdir/PLAN-99-smoke.state.json"

  local aws_block=""
  if [ "$variant" = "with_aws" ]; then
    aws_block='"aws_env": {"account":"111122223333","region":"ap-southeast-2","profile":"smoke-role","cdk_app_path":"infrastructure"},'
  fi

  cat > "$state_file" <<EOF
{
  ${aws_block}
  "plan_file": ".claude/plans/PLAN-99-smoke.md",
  "total_tasks": 1,
  "status": "in_progress",
  "auto_merge_overrides": {},
  "auto_recommended": false,
  "ingested_at": "2026-01-01T00:00:00Z",
  "tasks": {
    "1": {
      "title": "Smoke task",
      "depends_on": [],
      "touches": [],
      "issue": null,
      "pr": null,
      "status": "pending",
      "retries": 0,
      "max_turns": null
    }
  }
}
EOF
  echo "$state_file"
}

# ---------------------------------------------------------------------------
# Extract the env-var export block from launch-worker.sh and evaluate it
# against a given state file. Returns the exported vars as KEY=VALUE lines.
# ---------------------------------------------------------------------------
probe_aws_exports() {
  local state_file="$1"

  # Pull only the aws_env block from launch-worker.sh (between the two marker
  # comments) and run it in a subshell, then dump the five AWS vars.
  bash -c "
    STATE_FILE='$state_file'
    $(sed -n '/^# Propagate AWS env vars/,/^unset _AWS_ENV/p' "$SCRIPTS_DIR/launch-worker.sh")
    echo \"AWS_PROFILE=\${AWS_PROFILE:-}\"
    echo \"AWS_REGION=\${AWS_REGION:-}\"
    echo \"AWS_DEFAULT_REGION=\${AWS_DEFAULT_REGION:-}\"
    echo \"CDK_DEFAULT_ACCOUNT=\${CDK_DEFAULT_ACCOUNT:-}\"
    echo \"CDK_DEFAULT_REGION=\${CDK_DEFAULT_REGION:-}\"
  "
}

# ---------------------------------------------------------------------------
# Scenario 1: state WITH aws_env
# ---------------------------------------------------------------------------
echo "--- Scenario 1: aws_env present ---"
STATE_WITH=$(make_state "with_aws")
OUTPUT=$(probe_aws_exports "$STATE_WITH")

check_var() {
  local var="$1" expected="$2"
  local actual
  actual=$(echo "$OUTPUT" | grep "^${var}=" | cut -d= -f2-)
  if [ "$actual" = "$expected" ]; then
    pass "$var=$actual"
  else
    fail "$var: expected '$expected', got '$actual'"
  fi
}

check_var "AWS_PROFILE"        "smoke-role"
check_var "AWS_REGION"         "ap-southeast-2"
check_var "AWS_DEFAULT_REGION" "ap-southeast-2"
check_var "CDK_DEFAULT_ACCOUNT" "111122223333"
check_var "CDK_DEFAULT_REGION"  "ap-southeast-2"

rm -rf "$(dirname "$STATE_WITH")"

# ---------------------------------------------------------------------------
# Scenario 2: state WITHOUT aws_env — vars must be empty/unset
# ---------------------------------------------------------------------------
echo "--- Scenario 2: aws_env absent ---"
STATE_WITHOUT=$(make_state "no_aws")
OUTPUT=$(probe_aws_exports "$STATE_WITHOUT")

check_empty() {
  local var="$1"
  local actual
  actual=$(echo "$OUTPUT" | grep "^${var}=" | cut -d= -f2-)
  if [ -z "$actual" ]; then
    pass "$var correctly unset"
  else
    fail "$var should be empty, got '$actual'"
  fi
}

check_empty "AWS_PROFILE"
check_empty "AWS_REGION"
check_empty "AWS_DEFAULT_REGION"
check_empty "CDK_DEFAULT_ACCOUNT"
check_empty "CDK_DEFAULT_REGION"

rm -rf "$(dirname "$STATE_WITHOUT")"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$TESTS_FAILED" -eq 0 ]; then
  echo "All AWS env smoke tests passed."
  exit 0
else
  echo "$TESTS_FAILED test(s) failed." >&2
  exit 1
fi
