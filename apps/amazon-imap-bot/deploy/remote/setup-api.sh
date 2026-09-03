#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${DEPLOY_TARGET_FILE:-$SCRIPT_DIR/target.conf}"; SSH=(-i "$DEPLOY_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15)
echo "Preparando API remota..."
ssh "${SSH[@]}" "$DEPLOY_REMOTE_HOST" 'bash -s' -- "$DEPLOY_REMOTE_ROOT" "$DEPLOY_REMOTE_CONFIG_DIR" <<'REMOTE'
set -euo pipefail
ROOT="$1"; CONFIG="$2"; API="$ROOT/apps/api"; ENV="$API/config/production/app.env"; PORT="$(sed -n 's/^APP_PORT=//p' "$ENV")"; SERVICE="$(sed -n 's/^API_SYSTEMD_SERVICE=//p' "$ENV")"
sudo systemctl stop "$SERVICE" 2>/dev/null || true; sudo fuser -k "${PORT}/tcp" >/dev/null 2>&1 || true
rm -rf "$API/.venv"; python3 -m venv "$API/.venv"; "$API/.venv/bin/python" -m pip install --only-binary=oracledb -r "$API/requirements.txt"
"$ROOT/deploy/remote/systemd/install.sh" "$ROOT" "$CONFIG" "$SERVICE" api
REMOTE
exec "$SCRIPT_DIR/start-api.sh"
