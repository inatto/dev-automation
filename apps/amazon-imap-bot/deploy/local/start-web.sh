#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime.sh"

ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WEB_DIR="$ROOT_DIR/apps/web"

[[ -d "$WEB_DIR/node_modules" ]] || {
  echo "Web não preparada. Rode setup-web.sh." >&2
  exit 1
}

APP_PORT="$(sed -n 's/^APP_PORT=//p' "$WEB_DIR/config/local/app.env")"
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || {
  echo "Web local: APP_PORT inválida em config/local/app.env." >&2
  exit 1
}

runtime_stop_port_owner "$APP_PORT" "$ROOT_DIR" "Web local"

cd "$WEB_DIR"
echo "Iniciando Web local na porta $APP_PORT..."
AMAZON_IMAP_BOT_WEB_ENV=local setsid npm run dev &
PID=$!

shutdown() {
  trap - INT TERM EXIT
  runtime_stop_session "$PID" "Web local" 35
}
trap shutdown INT TERM EXIT

if runtime_wait_http_owned "$PID" "$APP_PORT" "http://127.0.0.1:${APP_PORT}/" "Web local" 40; then
  echo "Web local iniciada: http://127.0.0.1:${APP_PORT}/"
  wait "$PID"
  exit $?
fi

exit 1
