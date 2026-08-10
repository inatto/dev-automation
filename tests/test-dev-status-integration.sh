#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
APP="$PROJECT_ROOT/apps/dev-status"
AUTO="$PROJECT_ROOT/scripts/auto-code-manager.sh"
STATUS="$PROJECT_ROOT/scripts/dev-status.sh"

for file in \
  "$APP/src/main.cpp" \
  "$APP/CMakeLists.txt" \
  "$APP/build.ps1" \
  "$APP/invoke.ps1" \
  "$STATUS"; do
  [[ -f "$file" ]] || { printf 'FALHOU: arquivo ausente: %s\n' "$file" >&2; exit 1; }
done

grep -Fq 'Shell_NotifyIconW' "$APP/src/main.cpp"
grep -Fq 'NIF_GUID' "$APP/src/main.cpp"
grep -Fq 'kTrayGuid' "$APP/src/main.cpp"
grep -Fq 'SW_HIDE' "$APP/src/main.cpp"
grep -Fq 'WS_EX_TOOLWINDOW' "$APP/src/main.cpp"
grep -Fq 'CreateNamedPipeW' "$APP/src/main.cpp"
grep -Fq 'PIPE_REJECT_REMOTE_CLIENTS' "$APP/src/main.cpp"
grep -Fq 'SetEntriesInAclW' "$APP/src/main.cpp"
grep -Fq 'ShowTrayMenu' "$APP/src/main.cpp"
grep -Fq 'TrackPopupMenu' "$APP/src/main.cpp"
grep -Fq 'Pausar dev-manager' "$APP/src/main.cpp"
grep -Fq 'Despausar dev-manager' "$APP/src/main.cpp"
grep -Fq 'Desativar som' "$APP/src/main.cpp"
grep -Fq 'Ativar som' "$APP/src/main.cpp"
grep -Fq 'SetSoundDisabled(soundDisabledFile, !soundDisabled);' "$APP/src/main.cpp"
grep -Fq 'SetPaused(app.pauseFile, !paused);' "$APP/src/main.cpp"
grep -Fq 'case StatusCode::Paused: return L'"'"'P'"'"';' "$APP/src/main.cpp"
grep -Fq 'case StatusCode::Unzip: return RGB(70, 120, 255);' "$APP/src/main.cpp"
grep -Fq 'case StatusCode::Zip: return RGB(255, 0, 220);' "$APP/src/main.cpp"
grep -Fq 'case StatusCode::Clean: return RGB(255, 220, 0);' "$APP/src/main.cpp"
grep -Fq 'case StatusCode::Backup: return RGB(0, 230, 0);' "$APP/src/main.cpp"
grep -Fq 'case StatusCode::Sync: return RGB(0, 230, 230);' "$APP/src/main.cpp"
grep -Fq 'case StatusCode::Error: return RGB(255, 70, 70);' "$APP/src/main.cpp"
grep -Fq 'app.lastWorkState = packet.state;' "$APP/src/main.cpp"
grep -Fq 'SetTextColor(colorDc, statusColor);' "$APP/src/main.cpp"
grep -Fq 'HPEN colorPen = CreatePen(PS_SOLID, 3, statusColor);' "$APP/src/main.cpp"
grep -Fq 'tray_state_for_context()' "$AUTO"
grep -Fq 'taskbar_status "$(tray_state_for_context "$context")" "$title"' "$AUTO"
grep -Fq 'apps/dev-status/bin/' "$PROJECT_ROOT/config/auto-code-manager.ignore-zip"
grep -Fq 'taskbar_status backup "Gerando backups"' "$AUTO"
grep -Fq 'taskbar_status idle "Monitorando"' "$AUTO"
grep -Fq 'taskbar_status paused "Pausado"' "$AUTO"
grep -Fq 'taskbar_status exit "Auto Code Manager encerrado"' "$AUTO"
grep -Fq 'wait_if_paused()' "$AUTO"
grep -Fq 'sleep_with_pause()' "$AUTO"
grep -Fq 'SOUND_DISABLED_FILE="$STATE_DIR/dev-manager.sound-disabled"' "$AUTO"
grep -Fq '[ ! -f "$SOUND_DISABLED_FILE" ] || return 0' "$AUTO"
grep -Fq -- '-PauseFile "$pause_file_windows"' "$AUTO"
grep -Fq '[string]$PauseFile' "$APP/invoke.ps1"
grep -Fq '[ -f "$DEV_STATUS_EXE" ] || return 0' "$AUTO"
grep -Fq 'dev_status_needs_build' "$PROJECT_ROOT/scripts/dev-manager.sh"
grep -Fq 'dev-status.exe desatualizado; recompilando' "$PROJECT_ROOT/scripts/dev-manager.sh"

printf 'OK: dev-status tray nativo, pausa/despausa, som on/off e integração não bloqueante presentes\n'
