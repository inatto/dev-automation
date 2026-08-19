#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="$ROOT/apps/dev-status"
MANAGER="$ROOT/scripts/dev-manager.sh"
SOURCES=("$ROOT/scripts/auto-code-manager.sh" "$ROOT"/scripts/dev-manager/*.sh)

for file in "$ROOT/scripts/dev-status.sh" "$APP/src/main.cpp" "$APP/CMakeLists.txt"; do
  [ -f "$file" ] || { echo "FALHOU: ausente: $file" >&2; exit 1; }
done

grep -Fq 'taskbar_status()' "${SOURCES[@]}"
grep -Fq '[ -x "$DEV_STATUS_SCRIPT" ] || return 0' "${SOURCES[@]}"
grep -Fq 'TASKBAR_STATUS_ENABLED' "${SOURCES[@]}"

# O start padrão é mínimo: dev-status pode ser usado, mas não é compilado por surpresa.
START_BLOCK="$(sed -n '/start|run)/,/^    ;;/p' "$MANAGER")"
! grep -Fq 'ensure_dev_status' <<<"$START_BLOCK"

grep -Fq 'dev_status_needs_build()' "$MANAGER"
grep -Fq -- '--build|build)' "$ROOT/scripts/dev-status/linux.sh"

printf 'OK: dev-status continua opcional/não bloqueante e não é compilado automaticamente no start\n'
