#!/usr/bin/env bash
# Notify the operator of orchestrator events that need attention.
#
# Usage: .claude/scripts/notify.sh "<title>" "<message>"
#
# Tries in order:
#   1. Slack webhook if SLACK_WEBHOOK_URL is set
#   2. Discord webhook if DISCORD_WEBHOOK_URL is set
#   3. macOS notification (osascript)
#   4. Linux notification (notify-send)
#   5. Fallback: write to .claude/state/notifications.log

set -uo pipefail

TITLE="${1:-orchestrator}"
MESSAGE="${2:-(no message)}"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Always log
mkdir -p .claude/state
echo "[$TS] $TITLE: $MESSAGE" >> .claude/state/notifications.log

# Slack — fall through to next channel if delivery fails
if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  if curl -fsS -X POST -H "Content-Type: application/json" \
       --data "$(jq -n --arg t "$TITLE" --arg m "$MESSAGE" \
         '{text: ":robot_face: *\($t)*\n\($m)"}')" \
       "$SLACK_WEBHOOK_URL" >/dev/null 2>&1; then
    exit 0
  fi
  echo "[$TS] notify: Slack delivery failed, falling through" >> .claude/state/notifications.log
fi

# Discord
if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
  if curl -fsS -X POST -H "Content-Type: application/json" \
       --data "$(jq -n --arg t "$TITLE" --arg m "$MESSAGE" \
         '{content: "**\($t)**\n\($m)"}')" \
       "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1; then
    exit 0
  fi
  echo "[$TS] notify: Discord delivery failed, falling through" >> .claude/state/notifications.log
fi

# macOS
if command -v osascript >/dev/null 2>&1; then
  if osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\"" 2>/dev/null; then
    exit 0
  fi
fi

# Linux
if command -v notify-send >/dev/null 2>&1; then
  if notify-send "$TITLE" "$MESSAGE" 2>/dev/null; then
    exit 0
  fi
fi

# Fallback already covered by log file
exit 0
