#!/usr/bin/env bash
# Setup a local Odoo 19 ecommerce demo store (website + SAR/AED/USD switcher).
# Idempotent: steps that are already done are skipped.
# Supported hosts: macOS (Homebrew) and Ubuntu/Debian.
#
# Usage:
#   ./scripts/setup-website.sh
#
# Afterwards:
#   ./scripts/run-website.sh                # background
#   ./scripts/run-website.sh --foreground
#   ./scripts/run-website.sh --stop
#   ./scripts/run-website.sh --restart
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/demo_env.sh
source "$SCRIPT_DIR/lib/demo_env.sh"

REQ_STAMP="${VENV_DIR}/.tamara_demo_requirements.sha256"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Idempotent demo-store setup (deps, DB, website_sale, SAR/AED/USD pricelists).
Already-completed steps are skipped automatically.

Environment (.env or the shell):
  HTTP_EXPOSING_PORT
  DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD
  ODOO_CONF, VENV_DIR

  If DB_USER is set, PostgreSQL is not installed; those DB_* values are used as-is.
  If DB_USER is empty, a local PostgreSQL is installed and the OS user (no password) is used.

After setup:
  ./scripts/run-website.sh
  ./scripts/run-website.sh --foreground
  ./scripts/run-website.sh --stop
  ./scripts/run-website.sh --restart
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -gt 0 ]]; then
  die "Unknown argument: $1 (try --help). Start/stop live in run-website.sh."
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

ensure_dotenv() {
  if [[ -f "$ROOT_DIR/.env" ]]; then
    log ".env already exists"
    return
  fi
  if [[ -f "$ROOT_DIR/.env.example" ]]; then
    log "Creating .env from .env.example"
    cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"
  else
    log "Creating .env with default HTTP and Postgres settings"
    cat >"$ROOT_DIR/.env" <<EOF
HTTP_EXPOSING_PORT=${HTTP_EXPOSING_PORT}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=
EOF
  fi
}

ensure_macos_python() {
  command -v brew >/dev/null || die "Homebrew is required on macOS (https://brew.sh)."
  if ! command -v python3.12 >/dev/null && ! command -v python3 >/dev/null; then
    log "Installing Python 3.12 via Homebrew"
    brew install python@3.12
  fi
}

ensure_macos_psql_client() {
  if command -v psql >/dev/null; then
    log "PostgreSQL client already present"
    return
  fi
  log "Installing PostgreSQL client (libpq) via Homebrew"
  brew install libpq
  local libpq_bin
  libpq_bin="$(brew --prefix libpq)/bin"
  export PATH="${libpq_bin}:${PATH}"
  command -v psql >/dev/null || die "psql not found after installing libpq. Add ${libpq_bin} to PATH."
}

ensure_macos_postgres_server() {
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
}

ensure_ubuntu_python() {
  if command -v python3 >/dev/null; then
    log "Python already present"
    return
  fi
  log "Installing Python and build packages (sudo required)"
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3 python3-pip python3-venv python3-dev \
    libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev \
    libjpeg-dev libpq-dev build-essential \
    libffi-dev libssl-dev
}

ensure_ubuntu_psql_client() {
  if command -v psql >/dev/null; then
    log "PostgreSQL client already present"
    return
  fi
  log "Installing postgresql-client (sudo required)"
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-client
}

ensure_ubuntu_postgres_server() {
  if ! command -v psql >/dev/null || ! command -v python3 >/dev/null; then
    log "Installing system packages including PostgreSQL (sudo required)"
    sudo apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      python3 python3-pip python3-venv python3-dev \
      libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev \
      libjpeg-dev libpq-dev build-essential \
      postgresql postgresql-client libffi-dev libssl-dev
  else
    log "System packages already present; ensuring PostgreSQL is running"
  fi
  sudo service postgresql start 2>/dev/null || sudo systemctl start postgresql 2>/dev/null || true
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
    log "Creating PostgreSQL role ${DB_USER}"
    sudo -u postgres createuser -s "$DB_USER" || true
  fi
}

ensure_postgres() {
  if [[ "$DB_USER_PROVIDED" -eq 1 ]]; then
    log "DB_USER is set (${DB_USER}); skipping PostgreSQL install and using DB_* from .env"
    return
  fi
  if ! is_local_db_host; then
    die "DB_USER is empty but DB_HOST=${DB_HOST} is not local. Set DB_USER (and DB_PASSWORD) to use an existing PostgreSQL, or use DB_HOST=localhost to install locally."
  fi
  log "DB_USER is empty; installing local PostgreSQL (user ${DB_USER}, empty password)"
  DB_PASSWORD=""
  case "$(detect_os)" in
    macos) ensure_macos_postgres_server ;;
    ubuntu|linux) ensure_ubuntu_postgres_server ;;
  esac
  sync_db_connection_env
}

ensure_postgres_db_role() {
  command -v psql >/dev/null || die "psql not found after dependency install."
  if ! psql_demo postgres -c 'SELECT 1' >/dev/null 2>&1; then
    die "Cannot connect to PostgreSQL at ${DB_HOST}:${DB_PORT} as ${DB_USER}. Check DB_* in .env."
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
  local expected password_line
  if [[ -n "$DB_PASSWORD" ]]; then
    password_line="db_password = ${DB_PASSWORD}"
  else
    password_line="db_password = False"
  fi
  expected="$(cat <<EOF
[options]
admin_passwd = admin
db_host = ${DB_HOST}
db_port = ${DB_PORT}
db_user = ${DB_USER}
${password_line}
addons_path = ${ADDONS_PATH}
http_port = ${HTTP_EXPOSING_PORT}
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
  if psql_demo postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    log "Database ${DB_NAME} already exists"
  else
    log "Creating database ${DB_NAME}"
    createdb -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB_NAME"
  fi
}

module_installed() {
  local name="$1"
  psql_demo "$DB_NAME" -tAc \
    "SELECT 1 FROM information_schema.tables WHERE table_name='ir_module_module'" 2>/dev/null \
    | grep -q 1 \
    && psql_demo "$DB_NAME" -tAc \
      "SELECT 1 FROM ir_module_module WHERE name='${name}' AND state IN ('installed', 'to upgrade', 'to remove')" \
      2>/dev/null | grep -q 1
}

install_modules() {
  if module_installed website_sale; then
    log "website_sale already installed; skipping module install"
    return
  fi
  log "Installing website_sale on ${DB_NAME}"
  "$PYTHON" "$ODOO_BIN" \
    -c "$ODOO_CONF" \
    -d "$DB_NAME" \
    "${ODOO_DB_ARGS[@]}" \
    -i website_sale \
    --stop-after-init \
    --without-demo=False
}

configure_demo() {
  log "Configuring demo store (company, SAR/AED/USD switcher, products)"
  "$PYTHON" "$ODOO_BIN" shell \
    -c "$ODOO_CONF" \
    -d "$DB_NAME" \
    "${ODOO_DB_ARGS[@]}" \
    --stop-after-init <<'PY'
exec(open('scripts/configure_demo_store.py', encoding='utf-8').read())
PY
}

print_next_steps() {
  cat <<EOF

Demo store is ready.

  Database : ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}
  Config   : ${ODOO_CONF}
  HTTP port: ${HTTP_EXPOSING_PORT} (from .env HTTP_EXPOSING_PORT)
  Start    : ./scripts/run-website.sh
  Logs     : ./scripts/run-website.sh --foreground
  Restart  : ./scripts/run-website.sh --restart
  Stop     : ./scripts/run-website.sh --stop

Shop currencies: SAR, AED, USD (website pricelist switcher).
EOF
}

main() {
  local os
  os="$(detect_os)"
  log "Detected OS: $os"
  ensure_dotenv
  case "$os" in
    macos) ensure_macos_python ;;
    ubuntu|linux) ensure_ubuntu_python ;;
  esac
  if [[ "$DB_USER_PROVIDED" -eq 1 ]]; then
    case "$os" in
      macos) ensure_macos_psql_client ;;
      ubuntu|linux) ensure_ubuntu_psql_client ;;
    esac
  fi
  ensure_postgres
  ensure_postgres_db_role
  ensure_venv
  write_odoo_conf
  create_database
  install_modules
  configure_demo
  print_next_steps
}

main
