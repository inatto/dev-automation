#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"; API_DIR="$ROOT_DIR/apps/api"
"${API_DIR}/.venv/bin/python" -m pytest -q "$API_DIR/tests"
