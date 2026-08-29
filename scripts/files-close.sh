#!/usr/bin/env bash
# Fecha todas as janelas/processos principais do GNOME Files na sessão atual.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

case "${1:-}" in
  --help|-h|help)
    printf 'Uso: files-close\n'
    printf 'Fecha o Files/Nautilus pertencente à sessão gráfica atual.\n'
    exit 0
    ;;
  '') ;;
  *) printf '[files-close] ERRO: opção inválida: %s\n' "$1" >&2; exit 1 ;;
esac

exec bash "$SCRIPT_DIR/session-app-close.sh" files
