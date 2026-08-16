#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TUI="$ROOT/scripts/dev-manager-tui.py"
LEGACY="$ROOT/scripts/dev-manager/10-tui-legacy.sh"
LOGGING="$ROOT/scripts/dev-manager/20-status-logging.sh"

grep -Fq 'stamp_attr = (attr & ~curses.A_BOLD) | curses.A_DIM' "$TUI"
grep -Fq 'safe_add(logwin, i, 2, stamp, stamp_attr' "$TUI"
grep -Fq "printf '\\033[%s;2m[%s] \\033[%sm%s" "$LEGACY"
grep -Fq "printf '\\033[2;%sm[%s] \\033[0m'" "$LOGGING"

echo 'OK: timestamp usa o mesmo tom da linha com brilho reduzido.'
