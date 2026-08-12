#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT_DIR"
[[ -x .venv/bin/python ]] || { echo 'Execute exec-agent setup primeiro.' >&2; exit 1; }
exec .venv/bin/python -m agent.cli contaja-login
