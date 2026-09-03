# Shared env for Tamara Odoo demo scripts. Sourced by setup/run scripts.
# shellcheck shell=bash

# This file lives in scripts/lib/ — repo root is two levels up.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$_LIB_DIR/../.." && pwd)"
cd "$ROOT_DIR"

_dotenv_key_is_set() {
  local key="$1"
  eval "[ \"\${${key}+x}\" = x ]"
}

load_dotenv() {
  local env_file="${1:-$ROOT_DIR/.env}"
  [[ -f "$env_file" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    case "$line" in
      ''|\#*) continue ;;
    esac
    if [[ "$line" == export\ * ]]; then
      line="${line#export }"
    fi
    [[ "$line" == *"="* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if _dotenv_key_is_set "$key"; then
      continue
    fi
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    export "$key=$val"
  done <"$env_file"
}

if [[ ! -f "$ROOT_DIR/.env" && -f "$ROOT_DIR/.env.example" ]]; then
  cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"
fi
if [[ -f "$ROOT_DIR/.env" && -f "$ROOT_DIR/.env.example" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    [[ "$line" == *"="* ]] || continue
    key="${line%%=*}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}=" "$ROOT_DIR/.env"; then
      continue
    fi
    printf '%s\n' "$line" >>"$ROOT_DIR/.env"
  done <"$ROOT_DIR/.env.example"
fi
load_dotenv

HTTP_EXPOSING_PORT="${HTTP_EXPOSING_PORT:-${HTTP_PORT:-8069}}"
HTTP_PORT="$HTTP_EXPOSING_PORT"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-tamara_demo}"
# Non-empty DB_USER means "use an existing PostgreSQL"; empty means install locally.
if [[ -n "${DB_USER:-}" ]]; then
  DB_USER_PROVIDED=1
else
  DB_USER_PROVIDED=0
  DB_USER="$USER"
fi
DB_PASSWORD="${DB_PASSWORD:-}"
ODOO_CONF="${ODOO_CONF:-$ROOT_DIR/odoo.demo.conf}"
VENV_DIR="${VENV_DIR:-$ROOT_DIR/.venv}"
ADDONS_PATH="$ROOT_DIR/addons,$ROOT_DIR/odoo/addons,$ROOT_DIR/custom_addons"
RUN_DIR="${RUN_DIR:-$ROOT_DIR/.odoo_demo_run}"
PID_FILE="${PID_FILE:-$RUN_DIR/odoo.pid}"
LOG_FILE="${LOG_FILE:-$RUN_DIR/odoo.log}"
PYTHON="${VENV_DIR}/bin/python"
ODOO_BIN="$ROOT_DIR/odoo-bin"
NGROK_URL="${NGROK_URL:-}"
NGROK_ENABLED="${NGROK_ENABLED:-0}"
NGROK_PID_FILE="${NGROK_PID_FILE:-$RUN_DIR/ngrok.pid}"
NGROK_LOG_FILE="${NGROK_LOG_FILE:-$RUN_DIR/ngrok.log}"
NGROK_API_URL="${NGROK_API_URL:-http://127.0.0.1:4040/api/tunnels}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-}"

sync_db_connection_env() {
  export PGHOST="$DB_HOST"
  export PGPORT="$DB_PORT"
  export PGUSER="$DB_USER"
  export PGPASSWORD="$DB_PASSWORD"
  ODOO_DB_ARGS=(
    --db_host="$DB_HOST"
    --db_port="$DB_PORT"
    --db_user="$DB_USER"
  )
  if [[ -n "$DB_PASSWORD" ]]; then
    ODOO_DB_ARGS+=(--db_password="$DB_PASSWORD")
  fi
}
sync_db_connection_env

ODOO_RUNTIME_ARGS=(--http-port="$HTTP_EXPOSING_PORT")

normalize_public_url() {
  local url="${1:-}"
  url="${url%"${url##*[![:space:]]}"}"
  url="${url#"${url%%[![:space:]]*}"}"
  url="${url%/}"
  printf '%s' "$url"
}

ngrok_is_running() {
  [[ -f "$NGROK_PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$NGROK_PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

stop_ngrok() {
  local pid
  if ngrok_is_running; then
    pid="$(cat "$NGROK_PID_FILE")"
    log "Stopping ngrok (pid ${pid})"
    stop_pid "$pid"
  fi
  rm -f "$NGROK_PID_FILE"
}

fetch_ngrok_https_url() {
  "$PYTHON" - "$NGROK_API_URL" <<'PY'
import json, sys, time, urllib.error, urllib.request
api = sys.argv[1]
for _ in range(40):
    try:
        with urllib.request.urlopen(api, timeout=1) as resp:
            data = json.load(resp)
        for tunnel in data.get("tunnels") or []:
            url = tunnel.get("public_url") or ""
            if url.startswith("https://"):
                print(url.rstrip("/"))
                raise SystemExit(0)
    except urllib.error.URLError:
        pass
    time.sleep(0.25)
raise SystemExit(1)
PY
}

start_ngrok() {
  mkdir -p "$RUN_DIR"
  PUBLIC_BASE_URL="$(fetch_ngrok_https_url || true)"
  if [[ -n "$PUBLIC_BASE_URL" ]]; then
    NGROK_URL="$PUBLIC_BASE_URL"
    log "Using existing ngrok tunnel: ${PUBLIC_BASE_URL}"
    return
  fi
  command -v ngrok >/dev/null || die "ngrok is not installed. Install it from https://ngrok.com/download or set NGROK_URL and start ngrok yourself."
  local host=""
  if [[ -n "$NGROK_URL" ]]; then
    host="$(normalize_public_url "$NGROK_URL")"
    host="${host#https://}"
    host="${host#http://}"
    host="${host%%/*}"
  fi
  log "Starting ngrok tunnel to localhost:${HTTP_EXPOSING_PORT}"
  if [[ -n "$host" ]]; then
    nohup ngrok http --url="$host" "$HTTP_EXPOSING_PORT" >>"$NGROK_LOG_FILE" 2>&1 &
  else
    nohup ngrok http "$HTTP_EXPOSING_PORT" >>"$NGROK_LOG_FILE" 2>&1 &
  fi
  echo $! >"$NGROK_PID_FILE"
  sleep 1
  ngrok_is_running || die "ngrok failed to start. Check ${NGROK_LOG_FILE}"
  PUBLIC_BASE_URL="$(fetch_ngrok_https_url || true)"
  [[ -n "$PUBLIC_BASE_URL" ]] || die "Could not read the ngrok HTTPS URL from ${NGROK_API_URL}. Check ${NGROK_LOG_FILE}"
  NGROK_URL="$PUBLIC_BASE_URL"
  log "ngrok public URL: ${PUBLIC_BASE_URL}"
}

sync_odoo_runtime_args() {
  ODOO_RUNTIME_ARGS=(--http-port="$HTTP_EXPOSING_PORT")
  case "${PUBLIC_BASE_URL:-}" in
    https://*) ODOO_RUNTIME_ARGS+=(--proxy-mode) ;;
  esac
}

apply_public_base_url() {
  local url="${PUBLIC_BASE_URL:-http://localhost:${HTTP_EXPOSING_PORT}}"
  url="$(normalize_public_url "$url")"
  PUBLIC_BASE_URL="$url"
  log "Setting Odoo public URL to ${url}"
  PUBLIC_BASE_URL="$url" "$PYTHON" "$ODOO_BIN" shell \
    -c "$ODOO_CONF" \
    -d "$DB_NAME" \
    "${ODOO_DB_ARGS[@]}" \
    --no-http \
    --stop-after-init <<'PY'
import os

url = os.environ['PUBLIC_BASE_URL'].rstrip('/')
ICP = env['ir.config_parameter'].sudo()
ICP.set_param('web.base.url', url)
ICP.set_param('web.base.url.freeze', 'True')

# website.domain is unique, so only the demo website may hold the public URL.
if 'website' in env.registry:
    websites = env['website'].sudo().search([], order='id')
    target = websites[:1]
    if target:
        others = websites - target
        stale = others.filtered(lambda w: w.domain == url)
        if stale:
            stale.domain = False
            env.flush_all()
        if target.domain != url:
            target.domain = url
            env.flush_all()
env.cr.commit()
print(f'Public URL set to {url}')
PY
  sync_odoo_runtime_args
}

is_local_db_host() {
  case "$DB_HOST" in
    localhost|127.0.0.1|::1) return 0 ;;
    *) return 1 ;;
  esac
}

psql_demo() {
  local db="$1"
  shift
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$db" "$@"
}

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
  local public="${PUBLIC_BASE_URL:-http://localhost:${HTTP_EXPOSING_PORT}}"
  public="${public%/}"
  cat <<EOF
  Local shop : http://localhost:${HTTP_EXPOSING_PORT}/shop
  Local backend : http://localhost:${HTTP_EXPOSING_PORT}/web (admin / admin)
  Public URL : ${public}
  Public shop : ${public}/shop
  Webhook    : ${public}/payment/tamara/webhook
  Log file   : ${LOG_FILE}
EOF
  if [[ -n "${NGROK_LOG_FILE:-}" && -f "$NGROK_LOG_FILE" ]]; then
    printf '  ngrok log  : %s\n' "$NGROK_LOG_FILE"
  fi
}

stop_pid() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  if ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  log "Stopping process (pid ${pid})"
  kill "$pid" 2>/dev/null || true
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  log "Force-killing process (pid ${pid})"
  kill -9 "$pid" 2>/dev/null || true
}

stop_odoo() {
  local stopped=0
  local pid pids
  if service_is_running; then
    stop_pid "$(cat "$PID_FILE")"
    stopped=1
  fi
  pids="$(pgrep -f "odoo-bin.*$(basename "$ODOO_CONF")" 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    for pid in $pids; do
      stop_pid "$pid"
    done
    stopped=1
  fi
  rm -f "$PID_FILE"
  if [[ "$stopped" -eq 1 ]]; then
    log "Odoo stopped"
  else
    log "Odoo service is not running"
  fi
  stop_ngrok
}

ensure_runtime_ready() {
  [[ -x "$PYTHON" ]] || die "Virtualenv missing at $VENV_DIR. Run ./scripts/setup-website.sh first."
  [[ -f "$ODOO_CONF" ]] || die "Config missing at $ODOO_CONF. Run ./scripts/setup-website.sh first."
  psql_demo postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 \
    || die "Database ${DB_NAME} does not exist. Run ./scripts/setup-website.sh first."
}

start_odoo_background() {
  if service_is_running; then
    log "Odoo already running (pid $(cat "$PID_FILE"))"
    print_urls
    return 0
  fi
  mkdir -p "$RUN_DIR"
  rm -f "$PID_FILE"
  log "Starting Odoo in the background on port ${HTTP_EXPOSING_PORT} (log: ${LOG_FILE})"
  nohup "$PYTHON" "$ODOO_BIN" \
    -c "$ODOO_CONF" \
    -d "$DB_NAME" \
    "${ODOO_DB_ARGS[@]}" \
    "${ODOO_RUNTIME_ARGS[@]}" \
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
}

start_odoo_foreground() {
  if service_is_running; then
    die "Odoo already running (pid $(cat "$PID_FILE")). Use --stop or --restart."
  fi
  log "Starting Odoo in the foreground on port ${HTTP_EXPOSING_PORT} (Ctrl+C to stop)"
  print_urls
  if ngrok_is_running; then
    trap 'stop_ngrok' EXIT INT TERM
    "$PYTHON" "$ODOO_BIN" \
      -c "$ODOO_CONF" \
      -d "$DB_NAME" \
      "${ODOO_DB_ARGS[@]}" \
      "${ODOO_RUNTIME_ARGS[@]}"
    return $?
  fi
  exec "$PYTHON" "$ODOO_BIN" \
    -c "$ODOO_CONF" \
    -d "$DB_NAME" \
    "${ODOO_DB_ARGS[@]}" \
    "${ODOO_RUNTIME_ARGS[@]}"
}
