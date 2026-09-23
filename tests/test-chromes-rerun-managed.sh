#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
command -v node >/dev/null 2>&1 || { printf 'Teste requer Node.js.\n' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf 'Teste requer Python 3.\n' >&2; exit 1; }
node "$ROOT/tests/test-chromes-managed-controller.cjs"
python3 "$ROOT/tests/test-chromes-all-managed.py"
