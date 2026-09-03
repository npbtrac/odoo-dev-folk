#!/usr/bin/env bash
# Run the Tamara Odoo demo website.
#
# Usage:
#   ./scripts/run-website.sh                 # background
#   ./scripts/run-website.sh --foreground    # show logs in this terminal
#   ./scripts/run-website.sh --ngrok         # start ngrok and use its HTTPS URL
#   ./scripts/run-website.sh --stop          # stop Odoo and ngrok
#   ./scripts/run-website.sh --restart       # stop then start (background)
#   ./scripts/run-website.sh --restart --foreground --ngrok
#   ./scripts/run-website.sh --status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/demo_env.sh
source "$SCRIPT_DIR/lib/demo_env.sh"

DO_STOP=0
DO_RESTART=0
FOREGROUND=0
DO_STATUS=0
DO_NGROK=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --stop          Stop Odoo and ngrok
  --restart       Stop then start again
  --foreground    Run in this terminal and stream logs (default is background)
  --ngrok         Start an ngrok tunnel and set Odoo web.base.url to the HTTPS URL
  --status        Show whether the background service is running
  -h, --help      Show this help

Default (no options): start Odoo in the background.

.env:
  HTTP_EXPOSING_PORT, DB_*
  NGROK_URL       Public HTTPS URL (used as-is if --ngrok is not passed)
  NGROK_ENABLED=1 Same as always passing --ngrok
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop) DO_STOP=1 ;;
    --restart) DO_RESTART=1 ;;
    --foreground) FOREGROUND=1 ;;
    --ngrok) DO_NGROK=1 ;;
    --status) DO_STATUS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

case "${NGROK_ENABLED}" in
  1|true|TRUE|yes|YES) DO_NGROK=1 ;;
esac

if [[ "$DO_STATUS" -eq 1 ]]; then
  if [[ "$DO_STOP" -eq 1 || "$DO_RESTART" -eq 1 || "$FOREGROUND" -eq 1 ]]; then
    die "Do not combine --status with --stop, --restart, or --foreground."
  fi
  if [[ -n "$NGROK_URL" ]]; then
    PUBLIC_BASE_URL="$(normalize_public_url "$NGROK_URL")"
  fi
  if service_is_running; then
    printf 'Odoo is running (pid %s)\n' "$(cat "$PID_FILE")"
    print_urls
    if ngrok_is_running; then
      printf 'ngrok is running (pid %s)\n' "$(cat "$NGROK_PID_FILE")"
    fi
    exit 0
  fi
  printf 'Odoo is not running\n'
  exit 1
fi

if [[ "$DO_STOP" -eq 1 && "$DO_RESTART" -eq 0 ]]; then
  stop_odoo
  exit 0
fi

ensure_runtime_ready

if [[ "$DO_RESTART" -eq 1 || "$DO_STOP" -eq 1 ]]; then
  stop_odoo
fi

if [[ "$DO_NGROK" -eq 1 ]]; then
  start_ngrok
elif [[ -n "$NGROK_URL" ]]; then
  PUBLIC_BASE_URL="$(normalize_public_url "$NGROK_URL")"
  log "Using NGROK_URL from .env: ${PUBLIC_BASE_URL}"
  log "Start ngrok yourself, or re-run with --ngrok (NGROK_ENABLED=1)."
else
  PUBLIC_BASE_URL="http://localhost:${HTTP_EXPOSING_PORT}"
fi

apply_public_base_url

if [[ "$FOREGROUND" -eq 1 ]]; then
  start_odoo_foreground
fi

start_odoo_background
