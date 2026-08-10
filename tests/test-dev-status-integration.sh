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

grep -Fq 'ITaskbarList3' "$APP/src/main.cpp"
grep -Fq 'CreateNamedPipeW' "$APP/src/main.cpp"
grep -Fq 'PIPE_REJECT_REMOTE_CLIENTS' "$APP/src/main.cpp"
grep -Fq 'SetEntriesInAclW' "$APP/src/main.cpp"
grep -Fq 'taskbar_status backup "Gerando backups"' "$AUTO"
grep -Fq 'taskbar_status idle "Monitorando"' "$AUTO"
grep -Fq 'taskbar_status exit "Auto Code Manager encerrado"' "$AUTO"
grep -Fq '[ -f "$DEV_STATUS_EXE" ] || return 0' "$AUTO"

printf 'OK: dev-status nativo e integração não bloqueante presentes\n'
