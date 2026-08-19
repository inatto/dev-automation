#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT/scripts/auto-code-manager.sh"
SOURCES=("$SCRIPT" "$ROOT"/scripts/dev-manager/*.sh)

grep -Fq 'mapfile -t projects < <(backup_order_targets)' "${SOURCES[@]}" || {
  echo 'backup_all deve materializar backup_order_targets antes de iterar.' >&2
  exit 1
}
grep -Fq 'for project in "${projects[@]}"; do' "${SOURCES[@]}" || {
  echo 'backup_all deve iterar sobre array materializado.' >&2
  exit 1
}
grep -Fq -- '"$DEV_STATUS_SCRIPT" "$state" --pause-file "$PAUSE_FILE" --detail "$detail" \' "${SOURCES[@]}" || {
  echo 'taskbar_status deve isolar stdin do PowerShell.' >&2
  exit 1
}

echo 'OK: backup não pode perder projetos por consumo de stdin do status Windows.'
