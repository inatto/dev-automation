#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${DEPLOY_TARGET_FILE:-$SCRIPT_DIR/target.conf}"; SSH=(-i "$DEPLOY_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15)
echo "Preparando Web remota..."
ssh "${SSH[@]}" "$DEPLOY_REMOTE_HOST" 'bash -s' -- "$DEPLOY_REMOTE_ROOT" <<'REMOTE'
set -euo pipefail
ROOT="$1"; WEB="$ROOT/apps/web"; ENV="$WEB/config/production/app.env"; PORT="$(sed -n 's/^APP_PORT=//p' "$ENV")"; SERVICE="$(sed -n 's/^WEB_SYSTEMD_SERVICE=//p' "$ENV")"
sudo systemctl stop "$SERVICE" 2>/dev/null || true; sudo fuser -k "${PORT}/tcp" >/dev/null 2>&1 || true
cd "$WEB"; rm -rf .astro dist; npm ci; AMAZON_IMAP_BOT_WEB_ENV=production NODE_ENV=production npm run build; test -s dist/server/entry.mjs
"$ROOT/deploy/remote/systemd/install.sh" "$ROOT" "" "$SERVICE" web
REMOTE
exec "$SCRIPT_DIR/start-web.sh"
