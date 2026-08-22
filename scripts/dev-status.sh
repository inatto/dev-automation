#!/usr/bin/env bash
# Entrada única multiplataforma do indicador de status do dev-manager.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

platform="${DEV_STATUS_PLATFORM:-auto}"
if [[ "$platform" == auto ]]; then
  if command -v powershell.exe >/dev/null 2>&1; then
    platform=windows
  elif [[ "$(uname -s)" == Linux ]]; then
    platform=linux
  else
    printf '[dev-status] ERRO: ambiente não suportado\n' >&2
    exit 1
  fi
fi

case "$platform" in
  windows|wsl)
    exec "$SCRIPT_DIR/dev-status/windows.sh" "$@"
    ;;
  linux|ubuntu|gnome)
    exec "$SCRIPT_DIR/dev-status/linux.sh" "$@"
    ;;
  *)
    printf '[dev-status] ERRO: DEV_STATUS_PLATFORM inválido: %s\n' "$platform" >&2
    exit 1
    ;;
esac
