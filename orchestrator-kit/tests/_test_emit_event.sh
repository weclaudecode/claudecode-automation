#!/usr/bin/env bash
# Smoke test for emit_event in _dispatcher_lib.sh.
#
# emit_event appends one JSON line to .claude/state/events.jsonl. It is
# best-effort (never raises), wired at multiple lifecycle points, and
# rotates when the file exceeds ORCH_EVENTS_MAX_BYTES. This test pins the
# observable contract:
#
#   1. With extras   — line is `{ts, event} + extras`, all extra types
#                       preserved (string / number / bool).
#   2. Without extras — line is exactly `{ts, event}`.
#   3. Rotation      — when current file exceeds threshold before the
#                       write, the existing file is rotated to a
#                       timestamped name and a fresh file is started.
#   4. No-op safety  — emit_event in a directory that is not a git repo
#                       returns 0 and writes nothing.
#
# Runs in a throwaway git repo under tmpdir; never touches the kit's own
# .claude/state.
#
# Usage: bash orchestrator-kit/tests/_test_emit_event.sh
# Exit:  0 = all pass, 1 = any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$KIT_ROOT/.claude/scripts/_dispatcher_lib.sh"

TESTS_FAILED=0
fail() { echo "FAIL: $*" >&2; TESTS_FAILED=$((TESTS_FAILED + 1)); }
pass() { echo "PASS: $*"; }

TMPROOT=$(mktemp -d /tmp/_test_emit_event.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT INT TERM

# Stand up a throwaway git repo so `git rev-parse --show-toplevel` succeeds
# inside emit_event. The repo only needs to exist; no commits required.
REPO="$TMPROOT/repo"
mkdir -p "$REPO"
( cd "$REPO" && git init -q --initial-branch=main )

EVENTS="$REPO/.claude/state/events.jsonl"

# Source the lib in a subshell-safe way. emit_event is the only symbol we
# need; the rest of the lib's setup is harmless in a bare git repo.
# shellcheck source=../.claude/scripts/_dispatcher_lib.sh
source "$LIB"

# ─── 1. Single event with mixed-type extras ───────────────────────────────────
echo "--- 1: emit with string/number/bool extras ---"
(
  cd "$REPO"
  emit_event task_in_review "$(jq -cn \
    --arg plan "05" --argjson task 3 --argjson pr 142 --argjson auto true \
    '{plan: $plan, task: $task, pr: $pr, auto_merge: $auto}')"
)

if [ ! -f "$EVENTS" ]; then
  fail "events.jsonl not created after first emit"
else
  LINE=$(head -1 "$EVENTS")
  EVENT=$(jq -r '.event' <<<"$LINE")
  PLAN=$(jq -r '.plan' <<<"$LINE")
  TASK=$(jq -r '.task' <<<"$LINE")
  PR=$(jq -r '.pr' <<<"$LINE")
  AUTO=$(jq -r '.auto_merge' <<<"$LINE")
  TS=$(jq -r '.ts' <<<"$LINE")
  [ "$EVENT" = "task_in_review" ] && pass "event field = task_in_review" || fail "event field wrong: $EVENT"
  [ "$PLAN" = "05" ] && pass "string extra preserved (plan=05)" || fail "plan wrong: $PLAN"
  [ "$TASK" = "3" ] && pass "number extra preserved (task=3, not quoted)" || fail "task wrong: $TASK"
  [ "$PR" = "142" ] && pass "number extra preserved (pr=142)" || fail "pr wrong: $PR"
  [ "$AUTO" = "true" ] && pass "bool extra preserved (auto_merge=true)" || fail "auto_merge wrong: $AUTO"
  if [[ "$TS" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    pass "ts is ISO-8601 UTC"
  else
    fail "ts format unexpected: $TS"
  fi
fi

# ─── 2. Event without extras ──────────────────────────────────────────────────
echo "--- 2: emit without extras → {ts, event} only ---"
(
  cd "$REPO"
  emit_event ping_no_extras
)
LINE=$(tail -1 "$EVENTS")
# Two keys: ts + event. Any extra key would fail this assertion.
KEYS=$(jq -r 'keys | join(",")' <<<"$LINE")
if [ "$KEYS" = "event,ts" ]; then
  pass "no-extras line has exactly {ts, event}"
else
  fail "no-extras line has extra keys: $KEYS"
fi

# ─── 3. Rotation when size exceeds ORCH_EVENTS_MAX_BYTES ──────────────────────
# Pre-condition: events.jsonl already has 2 lines from tests 1 & 2 (~100B).
# Set threshold to 50 → next emit must rotate the existing file to a
# timestamped name and start fresh.
echo "--- 3: rotation when file exceeds threshold ---"
SIZE_BEFORE=$(wc -c < "$EVENTS" | tr -d ' ')
(
  cd "$REPO"
  ORCH_EVENTS_MAX_BYTES=50 emit_event rotate_trigger
)

ROTATED_COUNT=$(find "$REPO/.claude/state" -maxdepth 1 -name 'events.jsonl.*' | wc -l | tr -d ' ')
if [ "$ROTATED_COUNT" = "1" ]; then
  pass "rotation produced 1 timestamped archive file"
else
  fail "expected 1 rotated archive, got $ROTATED_COUNT (size_before=$SIZE_BEFORE)"
fi

# After rotation the current file should contain exactly one fresh line
# (the rotate_trigger event), not the prior history.
POST_LINES=$(wc -l < "$EVENTS" | tr -d ' ')
if [ "$POST_LINES" = "1" ]; then
  pass "fresh events.jsonl after rotation contains exactly the new line"
else
  fail "expected 1 line in fresh events.jsonl, got $POST_LINES"
fi
POST_EVENT=$(jq -r '.event' < "$EVENTS")
[ "$POST_EVENT" = "rotate_trigger" ] && pass "fresh line is the post-rotation event" \
  || fail "fresh line event wrong: $POST_EVENT"

# ─── 4. No-op outside a git repo (best-effort guarantee) ──────────────────────
# emit_event must NOT raise (set -e in the caller) when git rev-parse fails.
echo "--- 4: no-op + return 0 outside a git repo ---"
NOREPO="$TMPROOT/no_repo"
mkdir -p "$NOREPO"
(
  cd "$NOREPO"
  set -e
  if emit_event noop_test; then
    : # success
  else
    echo "EMIT_EVENT_RAISED" >&2
    exit 99
  fi
)
NOREPO_RC=$?
if [ "$NOREPO_RC" = "0" ]; then
  pass "emit_event returned 0 outside a git repo (no exception under set -e)"
else
  fail "emit_event raised or returned non-zero outside git repo (rc=$NOREPO_RC)"
fi
# And it must not have written anything to the cwd.
if [ ! -d "$NOREPO/.claude" ]; then
  pass "emit_event wrote nothing in non-repo cwd"
else
  fail "emit_event created .claude/ in non-repo cwd"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
if [ "$TESTS_FAILED" -gt 0 ]; then
  echo "RESULT: $TESTS_FAILED failure(s)" >&2
  exit 1
fi
echo "RESULT: all emit_event tests passed"
exit 0
