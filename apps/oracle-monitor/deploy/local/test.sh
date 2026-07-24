#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -m py_compile "$ROOT_DIR/apps/api/main.py"
cd "$ROOT_DIR/apps/web"
npm run build
echo "Testes estruturais concluídos."
