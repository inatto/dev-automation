#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WEB_DIR="$ROOT_DIR/apps/web"
[[ -f "$WEB_DIR/.env" ]] || cp "$WEB_DIR/.env.example" "$WEB_DIR/.env"
cd "$WEB_DIR"
rm -rf .astro
npm install
echo "Web Oracle Monitor preparada."
