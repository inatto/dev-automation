#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT/scripts/auto-code-manager.sh"

grep -Fq 'mapfile -t projects < <(backup_targets)' "$SCRIPT" || {
  echo 'backup_all deve materializar backup_targets antes de iterar.' >&2
  exit 1
}
grep -Fq 'for project in "${projects[@]}"; do' "$SCRIPT" || {
  echo 'backup_all deve iterar sobre array materializado.' >&2
  exit 1
}
grep -Fq -- '-File "$invoke_windows" -State "$state" -Detail "$detail" </dev/null >/dev/null 2>&1 || true' "$SCRIPT" || {
  echo 'taskbar_status deve isolar stdin do PowerShell.' >&2
  exit 1
}

echo 'OK: backup não pode perder projetos por consumo de stdin do status Windows.'
