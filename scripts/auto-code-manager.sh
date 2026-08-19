#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation
set -uo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SCRIPT_VERSION="$(cat "$PROJECT_ROOT/VERSION" 2>/dev/null || printf 'v34 | 20260818 21:52')"
DEV_MANAGER_MODULE_DIR="$SCRIPT_DIR/dev-manager"

# TUI principal: ncurses real (ACS/terminfo). O Bash continua sendo o motor.
# One-shots e execuções sem TTY continuam diretamente no shell.
maybe_exec_ncurses_tui() {
  [ -z "${DEV_MANAGER_TUI_CHILD:-}" ] || return 0
  [ "${AUTO_CODE_TUI:-clipper}" != "off" ] || return 0
  [ "$#" -eq 0 ] || return 0
  [ -t 0 ] && [ -t 1 ] || return 0
  [ -f "$SCRIPT_DIR/dev-manager-tui.py" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c 'import curses' >/dev/null 2>&1 || return 0
  exec python3 "$SCRIPT_DIR/dev-manager-tui.py" "$SCRIPT_PATH"
}

maybe_exec_ncurses_tui "$@"

DEV_MANAGER_MODULES=(
  00-runtime.sh
  10-tui-legacy.sh
  20-status-logging.sh
  30-sounds.sh
  40-files-safety.sh
  50-project-registry.sh
  80-backup-filters.sh
  90-sql-zip.sh
  100-protected-config.sh
  130-backups.sh
  140-light-monitor.sh
  150-inotify-plan.sh
  160-dirty-backups.sh
  170-inotify-runtime.sh
  180-lifecycle.sh
  190-config-gitcrypt-guard.sh
  900-main.sh
)

for module in "${DEV_MANAGER_MODULES[@]}"; do
  module_path="$DEV_MANAGER_MODULE_DIR/$module"
  if [ ! -f "$module_path" ]; then
    echo "ERRO: módulo obrigatório do dev-manager ausente: $module_path" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$module_path" || {
    echo "ERRO: falha ao carregar módulo do dev-manager: $module_path" >&2
    exit 1
  }
done
