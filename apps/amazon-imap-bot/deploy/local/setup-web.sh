#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WEB_DIR="$ROOT_DIR/apps/web"
APP_PORT="$(sed -n 's/^APP_PORT=//p' "$WEB_DIR/config/local/app.env")"
echo "Parando Web local na porta $APP_PORT..."
fuser -k "${APP_PORT}/tcp" >/dev/null 2>&1 || true
cd "$WEB_DIR"
rm -rf .astro dist
npm ci
npm test
echo "Web preparada."
exec "$SCRIPT_DIR/start-web.sh"
