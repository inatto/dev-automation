#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
VERSION="$(cat "$ROOT/VERSION")"
[[ "$VERSION" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{2}\.[0-9]{2}-v[0-9]+$ ]] || { echo "FALHOU: VERSION inválida: $VERSION" >&2; exit 1; }
grep -Fq 'self.prep_box(header, f"DEV AUTOMATION :: {self.version} :: CLIPPER / NCURSES")' "$ROOT/scripts/dev-manager-tui.py"
grep -Fq 'PROJECT_ROOT/VERSION' "$ROOT/scripts/auto-code-manager.sh"
echo "OK: versão no topo do dev-manager: $VERSION"
