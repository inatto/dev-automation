#!/usr/bin/env bash
# Entrada única multiplataforma do comando `files`.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
platform="${FILES_PLATFORM:-auto}"
if [[ "$platform" == auto ]]; then
  if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null || command -v powershell.exe >/dev/null 2>&1; then platform=windows; else platform=ubuntu; fi
fi
case "$platform" in
  windows|wsl) exec "$SCRIPT_DIR/files/windows.sh" "$@" ;;
  ubuntu|linux) exec "$SCRIPT_DIR/files/ubuntu.sh" "$@" ;;
  *) printf '[files] ERRO: plataforma inválida: %s\n' "$platform" >&2; exit 1 ;;
esac
