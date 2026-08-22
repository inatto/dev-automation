#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WEB_DIR="$ROOT_DIR/apps/web"
set -a; source "$WEB_DIR/.env"; set +a
cd "$WEB_DIR"
[[ -d node_modules ]] || { echo "Execute oracle-monitor setup primeiro." >&2; exit 1; }
echo "Monitor: http://localhost:${ORACLE_MONITOR_WEB_LOCAL_PORT}"
exec npm run dev -- --host "$ORACLE_MONITOR_WEB_LOCAL_HOST" --port "$ORACLE_MONITOR_WEB_LOCAL_PORT" --strictPort
