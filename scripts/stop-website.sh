#!/usr/bin/env bash
# Stop the Tamara Odoo demo website started with start-website.sh --service.
#
# Usage:
#   ./scripts/stop-website.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/demo_env.sh
source "$SCRIPT_DIR/lib/demo_env.sh"

stop_pid() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  if ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  log "Stopping Odoo (pid ${pid})"
  kill "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  log "Force-killing Odoo (pid ${pid})"
  kill -9 "$pid" 2>/dev/null || true
}

if service_is_running; then
  stop_pid "$(cat "$PID_FILE")"
  rm -f "$PID_FILE"
  log "Odoo stopped"
  exit 0
fi

# Fallback: processes started with this demo config (e.g. stale PID file).
pids="$(pgrep -f "odoo-bin.*$(basename "$ODOO_CONF")" 2>/dev/null || true)"
if [[ -n "$pids" ]]; then
  for pid in $pids; do
    stop_pid "$pid"
  done
  rm -f "$PID_FILE"
  log "Odoo stopped"
  exit 0
fi

rm -f "$PID_FILE"
log "Odoo service is not running"
