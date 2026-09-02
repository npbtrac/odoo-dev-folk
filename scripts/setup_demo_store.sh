#!/usr/bin/env bash
# Setup a local Odoo 19 ecommerce demo store with the Tamara payment provider.
# Idempotent: steps that are already done are skipped.
# Supported hosts: macOS (Homebrew) and Ubuntu/Debian.
#
# Usage:
#   ./scripts/setup_demo_store.sh
#   TAMARA_NOTIFICATION_TOKEN=your-token ./scripts/setup_demo_store.sh
#   DB_NAME=tamara_demo HTTP_PORT=8069 ./scripts/setup_demo_store.sh
#
# Afterwards:
#   ./scripts/start-website.sh              # foreground
#   ./scripts/start-website.sh --service    # background
#   ./scripts/stop-website.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/demo_env.sh
source "$SCRIPT_DIR/lib/demo_env.sh"

# Sandbox API token provided for local demos (Partners Portal sandbox merchant).
TAMARA_API_TOKEN="${TAMARA_API_TOKEN:-eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.eyJhY2NvdW50SWQiOiJhMDhiN2UyNi0yODZhLTQzM2YtOTllOS1jMTJkMmYzMzg0ZjQiLCJ0eXBlIjoibWVyY2hhbnQiLCJzYWx0IjoiYTcyMmU0ODRiZjcyMDUzNWZhMjc2ZTNmMjVjMTJjYjgiLCJpYXQiOjE2MzA2NDI0NzQsImlzcyI6IlRhbWFyYSJ9.lEzSf0e0VObbwqRRIaGrRAsXN3ouqljriIDYbthayzKsb5e6QvHCQ-_cRyWDdyy-meGYD2wzL8iXvxqGC2JvYEuEMAENexhqkuKGw4MvD7au2Gl1dJH0uFwr-zln3vVmnnKAibk0xlyL070I6xE526zUzfN7xq1mcbbhGkWvCari_vVYfyNwfkLAjJezWtcCJMXa_-5vVuK_NZQBjdQOsT6Za_LC4-De7Q24qHBgpUw8Ah8MTgmukrnGsjgVmjKepaHLwNOZyOvIcVa-US7mRmbvIRsfjBUOSpL7atXhCBkCSsV02IkqND0xABa37Wd2wsQ7dwxCStLH7p93iQl_rQ}"
TAMARA_NOTIFICATION_TOKEN="${TAMARA_NOTIFICATION_TOKEN:-}"
TAMARA_PUBLIC_KEY="${TAMARA_PUBLIC_KEY:-}"
REQ_STAMP="${VENV_DIR}/.tamara_demo_requirements.sha256"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Idempotent demo-store setup (deps, DB, modules, Tamara config).
Already-completed steps are skipped automatically.

Environment:
  DB_NAME, HTTP_PORT, ODOO_CONF, VENV_DIR
  TAMARA_API_TOKEN, TAMARA_NOTIFICATION_TOKEN, TAMARA_PUBLIC_KEY

After setup:
  ./scripts/start-website.sh
  ./scripts/start-website.sh --service
  ./scripts/stop-website.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -gt 0 ]]; then
  die "Unknown argument: $1 (try --help). Start/stop live in start-website.sh / stop-website.sh."
fi

detect_os() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)
      if [[ -f /etc/os-release ]] && grep -qi ubuntu /etc/os-release; then
        echo ubuntu
      else
        echo linux
      fi
      ;;
    *) die "Unsupported OS: $(uname -s). Use macOS or Ubuntu." ;;
  esac
}

ensure_macos_deps() {
  command -v brew >/dev/null || die "Homebrew is required on macOS (https://brew.sh)."
  if ! command -v psql >/dev/null; then
    log "Installing PostgreSQL via Homebrew"
    brew install postgresql@16
  else
    log "PostgreSQL client already present"
  fi
  if ! brew services list 2>/dev/null | grep -q 'postgresql.*started'; then
    log "Starting PostgreSQL"
    brew services start postgresql@16 2>/dev/null || brew services start postgresql 2>/dev/null || true
  else
    log "PostgreSQL already running"
  fi
  if ! command -v python3.12 >/dev/null && ! command -v python3 >/dev/null; then
    log "Installing Python 3.12 via Homebrew"
    brew install python@3.12
  fi
}

ensure_ubuntu_deps() {
  if command -v psql >/dev/null && command -v python3 >/dev/null; then
    log "System packages already present; ensuring PostgreSQL is running"
    sudo service postgresql start 2>/dev/null || sudo systemctl start postgresql 2>/dev/null || true
  else
    log "Installing system packages (sudo required)"
    sudo apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      python3 python3-pip python3-venv python3-dev \
      libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev \
      libjpeg-dev libpq-dev build-essential \
      postgresql postgresql-client libffi-dev libssl-dev
    sudo service postgresql start || sudo systemctl start postgresql || true
  fi
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${USER}'" | grep -q 1; then
    sudo -u postgres createuser -s "$USER" || true
  fi
}

ensure_postgres_db_role() {
  command -v psql >/dev/null || die "psql not found after dependency install."
  if ! psql -d postgres -c 'SELECT 1' >/dev/null 2>&1; then
    die "Cannot connect to PostgreSQL as ${USER}. Create a superuser role and retry."
  fi
}

requirements_hash() {
  if command -v shasum >/dev/null; then
    shasum -a 256 "$ROOT_DIR/requirements.txt" | awk '{print $1}'
  else
    sha256sum "$ROOT_DIR/requirements.txt" | awk '{print $1}'
  fi
}

ensure_venv() {
  local need_install=0
  if [[ ! -x "$PYTHON" ]]; then
    local py_bin
    if command -v python3.12 >/dev/null; then
      py_bin=python3.12
    else
      py_bin=python3
    fi
    log "Creating virtualenv at $VENV_DIR"
    "$py_bin" -m venv "$VENV_DIR"
    need_install=1
  else
    log "Virtualenv already exists at $VENV_DIR"
  fi

  local current_hash
  current_hash="$(requirements_hash)"
  if [[ "$need_install" -eq 1 || ! -f "$REQ_STAMP" || "$(cat "$REQ_STAMP" 2>/dev/null || true)" != "$current_hash" ]]; then
    log "Installing Python requirements"
    "$PYTHON" -m pip install --upgrade pip wheel setuptools
    "$PYTHON" -m pip install -r "$ROOT_DIR/requirements.txt"
    "$PYTHON" -m pip install 'psycopg2-binary>=2.9' || true
    printf '%s\n' "$current_hash" >"$REQ_STAMP"
  else
    log "Python requirements already installed (unchanged)"
  fi
}

write_odoo_conf() {
  local expected
  expected="$(cat <<EOF
[options]
admin_passwd = admin
db_user = ${USER}
addons_path = ${ADDONS_PATH}
http_port = ${HTTP_PORT}
list_db = True
EOF
)"
  if [[ -f "$ODOO_CONF" ]] && [[ "$(cat "$ODOO_CONF")" == "$expected" ]]; then
    log "Odoo config already up to date: $ODOO_CONF"
    return
  fi
  log "Writing $ODOO_CONF"
  printf '%s\n' "$expected" >"$ODOO_CONF"
}

create_database() {
  if psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    log "Database ${DB_NAME} already exists"
  else
    log "Creating database ${DB_NAME}"
    createdb "$DB_NAME"
  fi
}

module_installed() {
  local name="$1"
  psql -d "$DB_NAME" -tAc \
    "SELECT 1 FROM information_schema.tables WHERE table_name='ir_module_module'" 2>/dev/null \
    | grep -q 1 \
    && psql -d "$DB_NAME" -tAc \
      "SELECT 1 FROM ir_module_module WHERE name='${name}' AND state IN ('installed', 'to upgrade', 'to remove')" \
      2>/dev/null | grep -q 1
}

fetch_public_key_if_needed() {
  if [[ -n "$TAMARA_PUBLIC_KEY" ]]; then
    return
  fi
  log "Fetching Tamara sandbox public key from /merchants/configs"
  TAMARA_PUBLIC_KEY="$(
    curl -fsS \
      -H "Authorization: Bearer ${TAMARA_API_TOKEN}" \
      -H "Accept: application/json" \
      https://api-sandbox.tamara.co/merchants/configs \
      | "$PYTHON" -c 'import sys,json; print(json.load(sys.stdin).get("public_key",""))'
  )"
  [[ -n "$TAMARA_PUBLIC_KEY" ]] || die "Could not fetch Tamara public key. Set TAMARA_PUBLIC_KEY."
}

install_modules() {
  if module_installed payment_tamara && module_installed website_sale; then
    log "website_sale + payment_tamara already installed; upgrading payment_tamara"
    "$PYTHON" "$ODOO_BIN" \
      -c "$ODOO_CONF" \
      -d "$DB_NAME" \
      -u payment_tamara \
      --stop-after-init
    return
  fi
  log "Installing website_sale + payment_tamara on ${DB_NAME}"
  "$PYTHON" "$ODOO_BIN" \
    -c "$ODOO_CONF" \
    -d "$DB_NAME" \
    -i website_sale,payment_tamara \
    --stop-after-init \
    --without-demo=False
}

configure_demo() {
  log "Configuring demo store (company, currencies, products, Tamara)"
  if [[ -z "$TAMARA_NOTIFICATION_TOKEN" ]]; then
    log "TAMARA_NOTIFICATION_TOKEN is not set; using a placeholder (update it under Tamara > Settings for webhook JWT verification)."
    TAMARA_NOTIFICATION_TOKEN="sandbox-notification-token-placeholder"
  fi
  TAMARA_API_TOKEN="$TAMARA_API_TOKEN" \
  TAMARA_NOTIFICATION_TOKEN="$TAMARA_NOTIFICATION_TOKEN" \
  TAMARA_PUBLIC_KEY="$TAMARA_PUBLIC_KEY" \
  "$PYTHON" "$ODOO_BIN" shell \
    -c "$ODOO_CONF" \
    -d "$DB_NAME" \
    --stop-after-init <<'PY'
exec(open('scripts/configure_demo_store.py', encoding='utf-8').read())
PY
}

print_next_steps() {
  cat <<EOF

Demo store is ready.

  Database : ${DB_NAME}
  Config   : ${ODOO_CONF}
  Start    : ./scripts/start-website.sh
  Service  : ./scripts/start-website.sh --service
  Stop     : ./scripts/stop-website.sh

Tamara sandbox public key: ${TAMARA_PUBLIC_KEY:-"(set during setup)"}

Notes:
  - Set TAMARA_NOTIFICATION_TOKEN before relying on webhooks.
  - Webhooks require a public HTTPS URL (e.g. ngrok) → /payment/tamara/webhook.
  - Shop currencies: SAR, AED, USD (Tamara checkout: SAR + AED only).
EOF
}

main() {
  local os
  os="$(detect_os)"
  log "Detected OS: $os"
  case "$os" in
    macos) ensure_macos_deps ;;
    ubuntu|linux) ensure_ubuntu_deps ;;
  esac
  ensure_postgres_db_role
  ensure_venv
  write_odoo_conf
  create_database
  fetch_public_key_if_needed
  install_modules
  configure_demo
  print_next_steps
}

main
