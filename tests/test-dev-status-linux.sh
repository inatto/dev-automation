#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
LINUX_APP="$ROOT/apps/dev-status/linux"
DISPATCHER="$ROOT/scripts/dev-status.sh"
LINUX_WRAPPER="$ROOT/scripts/dev-status/linux.sh"
WINDOWS_WRAPPER="$ROOT/scripts/dev-status/windows.sh"
AUTO_RUNTIME="$ROOT/scripts/dev-manager/20-status-logging.sh"
MANAGER="$ROOT/scripts/dev-manager.sh"

for file in \
  "$LINUX_APP/src/main.cpp" \
  "$LINUX_APP/CMakeLists.txt" \
  "$LINUX_APP/build.sh" \
  "$LINUX_APP/icons/dev-status-idle.svg" \
  "$LINUX_APP/icons/dev-status-paused.svg" \
  "$LINUX_APP/icons/dev-status-error.svg" \
  "$DISPATCHER" "$LINUX_WRAPPER" "$WINDOWS_WRAPPER"; do
  [[ -f "$file" ]] || { printf 'FALHOU: arquivo ausente: %s\n' "$file" >&2; exit 1; }
done

grep -Fq 'AppIndicator* indicator' "$LINUX_APP/src/main.cpp"
grep -Fq 'app_indicator_new' "$LINUX_APP/src/main.cpp"
grep -Fq 'app_indicator_set_icon_full' "$LINUX_APP/src/main.cpp"
grep -Fq 'Pausar dev-manager' "$LINUX_APP/src/main.cpp"
grep -Fq 'Despausar dev-manager' "$LINUX_APP/src/main.cpp"
grep -Fq 'Desativar som' "$LINUX_APP/src/main.cpp"
grep -Fq 'Ativar som' "$LINUX_APP/src/main.cpp"
grep -Fq 'dev-manager.sound-disabled' "$LINUX_APP/src/main.cpp"
grep -Fq 'dev-status-linux.sock' "$LINUX_APP/src/main.cpp"
grep -Fq 'APP_INDICATOR_STATUS_ACTIVE' "$LINUX_APP/src/main.cpp"
grep -Fq 'pkg_check_modules(APPINDICATOR REQUIRED IMPORTED_TARGET ayatana-appindicator3-0.1)' "$LINUX_APP/CMakeLists.txt"
grep -Fq 'libayatana-appindicator3-dev' "$LINUX_APP/build.sh"
grep -Fq 'exec "$SCRIPT_DIR/dev-status/linux.sh" "$@"' "$DISPATCHER"
grep -Fq 'exec "$SCRIPT_DIR/dev-status/windows.sh" "$@"' "$DISPATCHER"
grep -Fq '"$DEV_STATUS_SCRIPT" "$state" --pause-file "$PAUSE_FILE" --detail "$detail"' "$AUTO_RUNTIME"
grep -Fq 'apps/dev-status/linux/bin/dev-status-linux' "$MANAGER"
grep -Fq 'apps/dev-status/linux/bin/' "$ROOT/config/auto-code-manager.ignore-zip"
grep -Fq 'apps/dev-status/linux/build/' "$ROOT/config/auto-code-manager.ignore-zip"

# O backend Windows continua fisicamente separado e preserva Win32.
grep -Fq 'Shell_NotifyIconW' "$ROOT/apps/dev-status/src/main.cpp"
grep -Fq 'powershell.exe' "$WINDOWS_WRAPPER"

# O dispatcher Linux deve chegar no backend Linux, não no PowerShell.
HELP="$(DEV_STATUS_PLATFORM=linux "$DISPATCHER" --help)"
grep -Fq 'Ubuntu/GNOME: indicador permanente via Ayatana AppIndicator.' <<<"$HELP"

# build.sh falha de forma explícita se as libs não estiverem instaladas; syntax sempre deve estar válida.
bash -n "$DISPATCHER" "$LINUX_WRAPPER" "$WINDOWS_WRAPPER" "$LINUX_APP/build.sh"

printf 'OK: dev-status Ubuntu separado em C++/Ayatana e Windows preservado em backend próprio\n'
