#!/usr/bin/env bash
# Fecha todos os processos principais Chrome/Chromium da sessão atual.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

case "${1:-}" in
  --help|-h|help)
    printf 'Uso: chromes-close\n'
    printf 'Fecha todas as instâncias Google Chrome/Chromium da sessão gráfica atual.\n'
    exit 0
    ;;
  '') ;;
  *) printf '[chromes-close] ERRO: opção inválida: %s\n' "$1" >&2; exit 1 ;;
esac

exec bash "$SCRIPT_DIR/session-app-close.sh" chromes
