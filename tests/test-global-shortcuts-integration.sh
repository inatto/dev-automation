#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
DIR="$ROOT/scripts/Global Shortcuts"
MANAGER="$DIR/Global-Shortcuts.sh"
ACTION="$DIR/digitar-data-hora.sh"
INSTALLER="$ROOT/deploy/local/install-commands.sh"

[[ -d "$DIR" ]]
[[ -x "$MANAGER" ]]
[[ -x "$ACTION" ]]

bash -n "$MANAGER"
bash -n "$ACTION"
bash -n "$INSTALLER"

grep -Fxq 'sleep 0.20' "$ACTION"
grep -Fxq 'export YDOTOOL_SOCKET="/run/ydotool-dm.sock"' "$ACTION"
grep -Fq 'exec /usr/bin/ydotool type --key-delay 2 "$(date '\''+%Y%m%d-%H%M'\'')"' "$ACTION"

grep -Fq 'GLOBAL_SHORTCUTS_SOURCE="$PROJECT_ROOT/scripts/Global Shortcuts/Global-Shortcuts.sh"' "$INSTALLER"
grep -Fq 'GLOBAL_SHORTCUTS_TARGET="$TARGET_DIR/Global-Shortcuts"' "$INSTALLER"
grep -Fq 'removido comando legado: digitar-data-hora' "$INSTALLER"
grep -Fq 'GLOBAL_SHORTCUTS_COMMAND="$GLOBAL_SHORTCUTS_TARGET" "$GLOBAL_SHORTCUTS_TARGET" ensure' "$INSTALLER"
grep -Fq 'command -v Global-Shortcuts' "$INSTALLER"
! grep -Fq 'command -v digitar-data-hora' "$INSTALLER"

grep -Fq 'command "$GLOBAL_SHORTCUTS_COMMAND digitar-data-hora"' "$MANAGER"
grep -Fq "binding '<Primary><Shift><Alt>d'" "$MANAGER"
grep -Fq 'ExecStart=/usr/bin/ydotoold --socket-path=/run/ydotool-dm.sock' "$MANAGER"
grep -Fq 'WantedBy=multi-user.target' "$MANAGER"
grep -Fq 'exec bash "$DIGITAR_DATA_HORA" "$@"' "$MANAGER"

grep -A20 -F 'start|run)' "$ROOT/scripts/dev-manager.sh" | grep -Fq 'refresh_global_commands'

printf 'OK: Global-Shortcuts centraliza registro/restauração e despacho dos atalhos\n'
