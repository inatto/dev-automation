#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${DEPLOY_TARGET_FILE:-$SCRIPT_DIR/target.conf}"; SSH=(-i "$DEPLOY_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15)
ssh "${SSH[@]}" "$DEPLOY_REMOTE_HOST" 'bash -s' -- "$DEPLOY_REMOTE_ROOT" <<'REMOTE'
set -euo pipefail
ROOT="$1"; "$ROOT/apps/api/.venv/bin/python" -m pytest -q "$ROOT/apps/api/tests"; cd "$ROOT/apps/web"; npm test
REMOTE
