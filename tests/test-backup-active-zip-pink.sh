#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
grep -Fq "zip_file) printf '1;38;5;197'" "$ROOT/scripts/dev-manager/20-status-logging.sh"
grep -Fq 'LOG_CONTEXT=zip_file log "Gerando backup:' "$ROOT/scripts/dev-manager/130-backups.sh"
grep -Fq '"zip_file": self.colors["zip_file"]' "$ROOT/scripts/dev-manager-tui.py"
grep -Fq 'zip_file = self.color_number(197, curses.COLOR_RED)' "$ROOT/scripts/dev-manager-tui.py"
printf 'OK: linha do ZIP ativo usa vermelho-pink dedicado\n'
