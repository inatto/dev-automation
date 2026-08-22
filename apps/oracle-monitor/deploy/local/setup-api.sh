#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
API_DIR="$ROOT_DIR/apps/api"
[[ -f "$API_DIR/.env" ]] || cp "$API_DIR/.env.example" "$API_DIR/.env"
cd "$API_DIR"
rm -rf .venv
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements.txt
echo "API Oracle Monitor preparada."
