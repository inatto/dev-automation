#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${DEPLOY_TARGET_FILE:-$SCRIPT_DIR/target.conf}"; SSH=(-i "$DEPLOY_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15)
ssh "${SSH[@]}" "$DEPLOY_REMOTE_HOST" 'bash -s' -- "$DEPLOY_REMOTE_ROOT" <<'REMOTE'
set -euo pipefail
ROOT="$1"; ENV="$ROOT/apps/api/config/production/app.env"; PORT="$(sed -n 's/^APP_PORT=//p' "$ENV")"; SERVICE="$(sed -n 's/^API_SYSTEMD_SERVICE=//p' "$ENV")"; sudo systemctl restart "$SERVICE"
for _ in {1..40}; do curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1 && exit 0; sleep 1; done
sudo systemctl status "$SERVICE" --no-pager -l >&2 || true; exit 1
REMOTE
echo "API remota iniciada."
