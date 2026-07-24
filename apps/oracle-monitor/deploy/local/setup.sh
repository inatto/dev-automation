#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/setup-web.sh"
"$SCRIPT_DIR/setup-api.sh"
echo "Ambiente pronto. Configure apps/api/.env e execute oracle-monitor start."
