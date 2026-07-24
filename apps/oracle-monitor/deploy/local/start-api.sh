#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
API_DIR="$ROOT_DIR/apps/api"
set -a; source "$API_DIR/.env"; set +a
cd "$API_DIR"
[[ -x .venv/bin/uvicorn ]] || { echo "Execute oracle-monitor setup primeiro." >&2; exit 1; }
echo "API: http://127.0.0.1:${APP_PORT}/docs"
exec .venv/bin/uvicorn main:app --reload --host "$APP_HOST" --port "$APP_PORT"
