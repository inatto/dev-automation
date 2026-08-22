#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BUILD="$ROOT/build"
BIN_DIR="$ROOT/bin"
BIN="$BIN_DIR/dev-status-linux"

fail() { printf '[dev-status/linux build] ERRO: %s\n' "$*" >&2; exit 1; }

for cmd in cmake pkg-config c++; do
  command -v "$cmd" >/dev/null 2>&1 || fail "dependência ausente: $cmd"
done

if ! pkg-config --exists gtk+-3.0 ayatana-appindicator3-0.1; then
  cat >&2 <<'MSG'
[dev-status/linux build] Dependências de desenvolvimento ausentes.
Instale no Ubuntu:
  sudo apt-get install -y build-essential cmake pkg-config libgtk-3-dev libayatana-appindicator3-dev
MSG
  exit 2
fi

mkdir -p "$BUILD" "$BIN_DIR"
cmake -S "$ROOT" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD" --parallel
cp -f "$BUILD/dev-status-linux" "$BIN"
chmod +x "$BIN"
printf '[dev-status/linux build] OK: %s\n' "$BIN"
