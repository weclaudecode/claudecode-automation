#!/usr/bin/env bash
# Launcher for the orchestrator local dashboard.
#
# Usage:
#   dashboard.sh start     — create venv if missing, install deps, launch
#   dashboard.sh stop      — kill the running dashboard (reads dashboard.pid)
#   dashboard.sh status    — print running|stopped + pid + port
#   dashboard.sh restart   — stop then start
#   dashboard.sh --help    — this message
#
# The dashboard binds to 127.0.0.1 only. Refuses to bind elsewhere even
# if env tries to override — exposing the operator dashboard on a
# non-loopback interface would create a credentials-adjacent attack
# surface with no auth layer. Tunnel via SSH if you need remote access.
#
# Env:
#   ORCH_DASHBOARD_PORT   default 5174

set -uo pipefail

REPO=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO" || { echo "dashboard: cd to repo root failed" >&2; exit 1; }

DASHBOARD_DIR=".claude/scripts/dashboard"
APP_PY="$DASHBOARD_DIR/app.py"
REQS="$DASHBOARD_DIR/requirements.txt"
VENV=".claude/state/dashboard-venv"
PID_FILE=".claude/state/dashboard.pid"
LOG_FILE=".claude/state/dashboard.log"
PORT="${ORCH_DASHBOARD_PORT:-5174}"

mkdir -p .claude/state

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

is_running() {
  [ -f "$PID_FILE" ] || return 1
  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

ensure_venv() {
  if [ ! -x "$VENV/bin/python" ]; then
    echo "dashboard: creating venv at $VENV"
    python3 -m venv "$VENV" || {
      echo "dashboard: python3 -m venv failed — is python3 installed?" >&2
      return 1
    }
  fi
  # Idempotent install. pip is quiet on no-op so this is cheap on repeat starts.
  "$VENV/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1 || true
  "$VENV/bin/pip" install --quiet -r "$REQS" || {
    echo "dashboard: pip install failed — see error above" >&2
    return 1
  }
}

cmd_start() {
  if is_running; then
    local pid; pid=$(cat "$PID_FILE")
    echo "dashboard: already running (pid $pid, port $PORT)"
    return 0
  fi
  if [ -f "$PID_FILE" ]; then
    echo "dashboard: removing stale pid file"
    rm -f "$PID_FILE"
  fi

  if [ ! -f "$APP_PY" ]; then
    echo "dashboard: $APP_PY not found — is the kit installed?" >&2
    return 1
  fi

  ensure_venv || return 1

  echo "dashboard: starting on http://127.0.0.1:$PORT (log: $LOG_FILE)"
  # PYTHONPATH so blueprint auto-discovery can import dashboard.api_*
  PYTHONPATH=".claude/scripts:${PYTHONPATH:-}" \
    ORCH_DASHBOARD_PORT="$PORT" \
    nohup "$VENV/bin/python" "$APP_PY" >> "$LOG_FILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"

  # Give Flask a moment to either bind or fail
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "dashboard: process died immediately — last 20 lines of $LOG_FILE:" >&2
    tail -20 "$LOG_FILE" >&2
    rm -f "$PID_FILE"
    return 1
  fi
  echo "dashboard: started (pid $pid)"
}

cmd_stop() {
  if [ ! -f "$PID_FILE" ]; then
    echo "dashboard: not running (no pid file)"
    return 0
  fi
  local pid; pid=$(cat "$PID_FILE")
  if [ -z "$pid" ]; then
    echo "dashboard: empty pid file, removing"
    rm -f "$PID_FILE"
    return 0
  fi
  if kill -0 "$pid" 2>/dev/null; then
    echo "dashboard: stopping pid $pid"
    kill "$pid" 2>/dev/null || true
    # Give it 2s to exit cleanly, then SIGKILL
    for _ in 1 2 3 4; do
      sleep 0.5
      if ! kill -0 "$pid" 2>/dev/null; then break; fi
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "dashboard: SIGKILL pid $pid"
      kill -9 "$pid" 2>/dev/null || true
    fi
  else
    echo "dashboard: pid $pid not running (stale pid file)"
  fi
  rm -f "$PID_FILE"
  echo "dashboard: stopped"
}

cmd_status() {
  if is_running; then
    local pid; pid=$(cat "$PID_FILE")
    echo "running (pid $pid, port $PORT)"
  else
    echo "stopped"
  fi
}

cmd_restart() {
  cmd_stop
  cmd_start
}

case "${1:-}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  restart) cmd_restart ;;
  -h|--help|help|"") usage ;;
  *)
    echo "dashboard: unknown subcommand: $1" >&2
    usage
    exit 2
    ;;
esac
