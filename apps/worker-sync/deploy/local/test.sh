#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
ROOT="$(cd -- "$APP_ROOT/../.." && pwd -P)"

grep -q 'copyto "$remote_source" "$staged"' "$APP_ROOT/scripts/download-from.sh"
grep -q 'JÁ PROCESSADO LOCALMENTE:' "$APP_ROOT/scripts/download-from.sh"
grep -q 'MAX_BATCH=' "$APP_ROOT/scripts/download-from.sh"
grep -q 'bounded_rclone' "$APP_ROOT/scripts/download-from.sh"
if grep -Eq 'REMOTE_PROCESSING|moveto .*REMOTE_DIR' "$APP_ROOT/scripts/download-from.sh"; then
  echo 'ERRO: downloader ainda move a origem remota' >&2
  exit 1
fi

grep -q 'copyto "$archive_path" "$remote_backup_target"' "$APP_ROOT/scripts/delete-from-watch.sh"
grep -q 'deletefile "$remote_source"' "$APP_ROOT/scripts/delete-from-watch.sh"
grep -q 'COLISÃO DE NOME\|colisão de nome' "$APP_ROOT/scripts/delete-from-watch.sh" || true
grep -q -- '--event close_write,moved_to' "$APP_ROOT/scripts/delete-from-watch.sh"
if grep -Eq 'PROCESSED|FAILED|original_name_from_archive|claim' "$APP_ROOT/scripts/delete-from-watch.sh"; then
  echo 'ERRO: backup worker ainda depende de renomeação/claim' >&2
  exit 1
fi

grep -q 'archive_path="$backup_dir/$base"' "$ROOT/scripts/dev-manager/70-imports.sh"
grep -q 'SEM RENOMEAR' "$ROOT/scripts/dev-manager/70-imports.sh"
if grep -q 'archive_name=.*PROCESSED' "$ROOT/scripts/dev-manager/70-imports.sh"; then
  echo 'ERRO: dev-manager ainda gera nome de histórico' >&2
  exit 1
fi

grep -q '^TimeoutStartSec=90s$' "$APP_ROOT/systemd/user/dev-automation-worker-from.service"
grep -q '^OnUnitInactiveSec=3s$' "$APP_ROOT/systemd/user/dev-automation-worker-from.timer"

echo 'worker-sync local test: OK'
