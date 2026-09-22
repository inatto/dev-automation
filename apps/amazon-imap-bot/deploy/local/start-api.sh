#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime.sh"

ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
API_DIR="$ROOT_DIR/apps/api"
DEV_AUTOMATION_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
CONFIG_ROOT="$DEV_AUTOMATION_ROOT/.config/amazon-imap-bot"

[[ -x "$API_DIR/.venv/bin/python" ]] || {
  echo "API não preparada. Rode setup-api.sh." >&2
  exit 1
}

APP_PORT="$(sed -n 's/^APP_PORT=//p' "$API_DIR/config/local/app.env")"
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || {
  echo "API local: APP_PORT inválida em config/local/app.env." >&2
  exit 1
}

runtime_stop_port_owner "$APP_PORT" "$ROOT_DIR" "API local"

cd "$API_DIR"
echo "Iniciando API local na porta $APP_PORT..."
AMAZON_IMAP_BOT_CONFIG_ENV=local \
AMAZON_IMAP_BOT_CONFIG_ROOT="$CONFIG_ROOT" \
setsid .venv/bin/python main.py &
PID=$!

shutdown() {
  trap - INT TERM EXIT
  runtime_stop_session "$PID" "API local" 30
}
trap shutdown INT TERM EXIT

if runtime_wait_http_owned "$PID" "$APP_PORT" "http://127.0.0.1:${APP_PORT}/api/health" "API local" 40; then
  echo "API local iniciada."
  wait "$PID"
  exit $?
fi

exit 1
