#!/usr/bin/env bash
# Start the Tamara Odoo demo website.
#
# Usage:
#   ./scripts/start-website.sh              # foreground
#   ./scripts/start-website.sh --service    # background service (PID + log)
#   ./scripts/start-website.sh --status
#   DB_NAME=tamara_demo HTTP_PORT=8069 ./scripts/start-website.sh --service
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/demo_env.sh
source "$SCRIPT_DIR/lib/demo_env.sh"

AS_SERVICE=0
DO_STATUS=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --service    Start Odoo in the background (PID/log under .odoo_demo_run/)
  --status     Show whether the background service is running
  -h, --help   Show this help

Default (no --service): start Odoo in the foreground.

Environment: DB_NAME, HTTP_PORT, ODOO_CONF, VENV_DIR
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) AS_SERVICE=1 ;;
    --status) DO_STATUS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

if [[ "$DO_STATUS" -eq 1 ]]; then
  if service_is_running; then
    printf 'Odoo is running (pid %s)\n' "$(cat "$PID_FILE")"
    print_urls
    exit 0
  fi
  printf 'Odoo is not running\n'
  exit 1
fi

[[ -x "$PYTHON" ]] || die "Virtualenv missing at $VENV_DIR. Run ./scripts/setup_demo_store.sh first."
[[ -f "$ODOO_CONF" ]] || die "Config missing at $ODOO_CONF. Run ./scripts/setup_demo_store.sh first."
psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 \
  || die "Database ${DB_NAME} does not exist. Run ./scripts/setup_demo_store.sh first."

if [[ "$AS_SERVICE" -eq 1 ]]; then
  if service_is_running; then
    log "Odoo already running (pid $(cat "$PID_FILE"))"
    print_urls
    exit 0
  fi
  mkdir -p "$RUN_DIR"
  rm -f "$PID_FILE"
  log "Starting Odoo service on port ${HTTP_PORT} (log: ${LOG_FILE})"
  nohup "$PYTHON" "$ODOO_BIN" \
    -c "$ODOO_CONF" \
    -d "$DB_NAME" \
    >>"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  sleep 1
  if service_is_running; then
    log "Odoo started (pid $(cat "$PID_FILE"))"
    print_urls
  else
    rm -f "$PID_FILE"
    die "Odoo failed to start. Check ${LOG_FILE}"
  fi
  exit 0
fi

log "Starting Odoo in the foreground on port ${HTTP_PORT} (Ctrl+C to stop)"
print_urls
exec "$PYTHON" "$ODOO_BIN" -c "$ODOO_CONF" -d "$DB_NAME"
