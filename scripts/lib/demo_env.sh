# Shared env for Tamara Odoo demo scripts. Sourced by setup/start/stop scripts.
# shellcheck shell=bash

# This file lives in scripts/lib/ — repo root is two levels up.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$_LIB_DIR/../.." && pwd)"
cd "$ROOT_DIR"

DB_NAME="${DB_NAME:-tamara_demo}"
HTTP_PORT="${HTTP_PORT:-8069}"
ODOO_CONF="${ODOO_CONF:-$ROOT_DIR/odoo.demo.conf}"
VENV_DIR="${VENV_DIR:-$ROOT_DIR/.venv}"
ADDONS_PATH="$ROOT_DIR/addons,$ROOT_DIR/odoo/addons,$ROOT_DIR/custom_addons"
RUN_DIR="${RUN_DIR:-$ROOT_DIR/.odoo_demo_run}"
PID_FILE="${PID_FILE:-$RUN_DIR/odoo.pid}"
LOG_FILE="${LOG_FILE:-$RUN_DIR/odoo.log}"
PYTHON="${VENV_DIR}/bin/python"
ODOO_BIN="$ROOT_DIR/odoo-bin"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

service_is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

print_urls() {
  cat <<EOF
  Shop URL : http://localhost:${HTTP_PORT}/shop
  Backend  : http://localhost:${HTTP_PORT}/web (admin / admin)
  Log file : ${LOG_FILE}
EOF
}
