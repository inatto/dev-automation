#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WEB_DIR="$ROOT_DIR/apps/web"
[[ -d "$WEB_DIR/node_modules" ]] || { echo "Web não preparada. Rode setup-web.sh." >&2; exit 1; }
APP_PORT="$(sed -n 's/^APP_PORT=//p' "$WEB_DIR/config/local/app.env")"
cd "$WEB_DIR"
echo "Iniciando Web local na porta $APP_PORT..."
AMAZON_IMAP_BOT_WEB_ENV=local setsid npm run dev & PID=$!
trap 'kill -TERM -- -$PID 2>/dev/null || true; wait $PID 2>/dev/null || true' INT TERM EXIT
for _ in {1..40}; do curl -fsS --max-time 2 "http://127.0.0.1:${APP_PORT}/" >/dev/null 2>&1 && { echo "Web local iniciada: http://127.0.0.1:${APP_PORT}/"; wait "$PID"; exit $?; }; kill -0 "$PID" 2>/dev/null || { echo "Web encerrou durante a inicialização." >&2; exit 1; }; sleep 1; done
echo "Web não ficou pronta." >&2; exit 1
