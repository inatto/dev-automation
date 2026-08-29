#!/usr/bin/env bash
# Alias explícito para o fechamento seguro já implementado em `pycharms --close`.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

case "${1:-}" in
  --help|-h|help)
    printf 'Uso: pycharms-close\n'
    printf 'Fecha todas as janelas PyCharm usando o controlador GNOME do Dev Automation.\n'
    exit 0
    ;;
  '') ;;
  *) printf '[pycharms-close] ERRO: opção inválida: %s\n' "$1" >&2; exit 1 ;;
esac

exec bash "$SCRIPT_DIR/pycharms.sh" --close
