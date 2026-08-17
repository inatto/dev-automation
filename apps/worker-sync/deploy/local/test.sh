#!/usr/bin/env bash
set -euo pipefail
APP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
ROOT="$(cd -- "$APP_ROOT/../.." && pwd -P)"

bash -n "$APP_ROOT/scripts/upload-watch.sh"
bash -n "$APP_ROOT/scripts/download-from.sh"
bash -n "$APP_ROOT/scripts/delete-from-watch.sh"
bash -n "$APP_ROOT/deploy/local/install.sh"
bash -n "$APP_ROOT/deploy/local/ensure.sh"
bash -n "$APP_ROOT/deploy/local/start.sh"
bash -n "$APP_ROOT/deploy/local/stop.sh"
bash -n "$APP_ROOT/deploy/local/status.sh"

grep -q 'LOCAL_DIR="${WORKER_LOCAL_TO:-/home/daniel/worker/to}"' "$APP_ROOT/scripts/upload-watch.sh"
grep -q 'REMOTE_DIR="${WORKER_REMOTE_TO:-danielmaiax:worker/to}"' "$APP_ROOT/scripts/upload-watch.sh"
grep -q 'copyto "$changed" "$dest"' "$APP_ROOT/scripts/upload-watch.sh"
grep -q 'REMOTE_DIR="${WORKER_REMOTE_FROM:-danielmaiax:worker/from}"' "$APP_ROOT/scripts/download-from.sh"
grep -q 'LOCAL_DIR="${WORKER_LOCAL_FROM:-/home/daniel/worker/from}"' "$APP_ROOT/scripts/download-from.sh"
grep -q -- "--exclude '/backup/\\*\\*'" "$APP_ROOT/scripts/download-from.sh"

grep -q 'REMOTE_BACKUP="$REMOTE_DIR/backup"' "$APP_ROOT/scripts/delete-from-watch.sh"
grep -q 'copy "$REMOTE_BACKUP" "$BACKUP_DIR"' "$APP_ROOT/scripts/delete-from-watch.sh"
grep -q 'copy "$BACKUP_DIR" "$REMOTE_BACKUP"' "$APP_ROOT/scripts/delete-from-watch.sh"
grep -q 'copyto "$archive_path" "$remote_target"' "$APP_ROOT/scripts/delete-from-watch.sh"
grep -q 'deletefile "$remote_source"' "$APP_ROOT/scripts/delete-from-watch.sh"
grep -q -- '--event close_write,moved_to' "$APP_ROOT/scripts/delete-from-watch.sh"
grep -q 'archive_worker_from_zip' "$ROOT/scripts/dev-manager/70-imports.sh"
grep -q 'ZIP ARQUIVADO LOCALMENTE:' "$ROOT/scripts/dev-manager/70-imports.sh"
grep -q 'refresh_worker_sync_after_self_update' "$ROOT/scripts/dev-manager/70-imports.sh"
grep -q 'SELF-UPDATE: worker-sync recarregado e backup reconciliado.' "$ROOT/scripts/dev-manager/70-imports.sh"

grep -q 'FINGERPRINT_FILE=' "$APP_ROOT/deploy/local/ensure.sh"
grep -q 'dev-automation-worker-from-delete.service' "$APP_ROOT/deploy/local/ensure.sh"
grep -q '^OnUnitInactiveSec=2s$' "$APP_ROOT/systemd/user/dev-automation-worker-from.timer"
if grep -R -E 'danielmaiax:worker/from.*(/home/daniel/worker/to)|/home/daniel/worker/from.*danielmaiax:worker/from' "$APP_ROOT/scripts"; then
  echo 'ERRO: direção worker inválida encontrada' >&2
  exit 1
fi
printf '[worker-sync] testes estruturais OK\n'
