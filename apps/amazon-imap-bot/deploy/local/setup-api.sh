#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
API_DIR="$ROOT_DIR/apps/api"
DEV_AUTOMATION_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
CONFIG_ROOT="$DEV_AUTOMATION_ROOT/.config/amazon-imap-bot"
APP_PORT="$(sed -n 's/^APP_PORT=//p' "$API_DIR/config/local/app.env")"
echo "Parando API local na porta $APP_PORT..."
fuser -k "${APP_PORT}/tcp" >/dev/null 2>&1 || true
echo "Preparando API Python..."
rm -rf "$API_DIR/.venv"
python3 -m venv "$API_DIR/.venv"
"$API_DIR/.venv/bin/python" -m pip install --only-binary=oracledb -r "$API_DIR/requirements.txt"
AMAZON_IMAP_BOT_CONFIG_ENV=local AMAZON_IMAP_BOT_CONFIG_ROOT="$CONFIG_ROOT" "$API_DIR/.venv/bin/python" -m pytest -q "$API_DIR/tests" 2>/dev/null || true
echo "API preparada."
exec "$SCRIPT_DIR/start-api.sh"
