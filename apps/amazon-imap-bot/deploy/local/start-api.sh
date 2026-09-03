#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
API_DIR="$ROOT_DIR/apps/api"
DEV_AUTOMATION_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
CONFIG_ROOT="$DEV_AUTOMATION_ROOT/.config/amazon-imap-bot"
[[ -x "$API_DIR/.venv/bin/python" ]] || { echo "API não preparada. Rode setup-api.sh." >&2; exit 1; }
APP_PORT="$(sed -n 's/^APP_PORT=//p' "$API_DIR/config/local/app.env")"
cd "$API_DIR"
echo "Iniciando API local na porta $APP_PORT..."
AMAZON_IMAP_BOT_CONFIG_ENV=local AMAZON_IMAP_BOT_CONFIG_ROOT="$CONFIG_ROOT" setsid .venv/bin/python main.py & PID=$!
shutdown(){
  trap - INT TERM EXIT
  kill -TERM -- "-$PID" 2>/dev/null || true
  for _ in {1..30}; do
    kill -0 "$PID" 2>/dev/null || { wait "$PID" 2>/dev/null || true; return; }
    sleep 0.1
  done
  echo "API não encerrou em 3s; forçando processo local." >&2
  kill -KILL -- "-$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
}
trap shutdown INT TERM EXIT
for _ in {1..40}; do curl -fsS --max-time 2 "http://127.0.0.1:${APP_PORT}/api/health" >/dev/null 2>&1 && { echo "API local iniciada."; wait "$PID"; exit $?; }; kill -0 "$PID" 2>/dev/null || { echo "API encerrou durante a inicialização." >&2; exit 1; }; sleep 1; done
echo "API não ficou pronta." >&2; exit 1
