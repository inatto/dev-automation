#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT/scripts/terminals-close.sh"
INSTALLER="$ROOT/deploy/local/install-commands.sh"

bash -n "$SCRIPT"
bash -n "$INSTALLER"
grep -Fq 'TERMINALS_CLOSE_SOURCE="$PROJECT_ROOT/scripts/terminals-close.sh"' "$INSTALLER"
grep -Fq 'terminals terminals-close chatgpts' "$INSTALLER"
grep -Fq 'terminals-close) source_file="$TERMINALS_CLOSE_SOURCE"' "$INSTALLER"
grep -Fq 'WAYLAND_DISPLAY' "$SCRIPT"
grep -Fq 'DISPLAY' "$SCRIPT"
grep -Fq 'XDG_SESSION_ID' "$SCRIPT"
grep -Fq 'kill -TERM "$pid"' "$SCRIPT"
grep -Fq 'Somente processos de emuladores gráficos' "$SCRIPT"

printf 'ok: terminals-close global e restrito à sessão gráfica\n'
