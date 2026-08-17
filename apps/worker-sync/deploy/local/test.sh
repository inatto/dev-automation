#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
ROOT="$(cd -- "$APP_ROOT/../.." && pwd -P)"

grep -q 'REMOTE_PROCESSING="$REMOTE_DIR/.processing"' "$APP_ROOT/scripts/download-from.sh"
grep -q 'moveto "$REMOTE_DIR/$original" "$processing"' "$APP_ROOT/scripts/download-from.sh"
grep -q 'copyto "$processing" "$staged"' "$APP_ROOT/scripts/download-from.sh"
grep -q 'worker_from_claim_prepare' "$APP_ROOT/scripts/download-from.sh"
grep -q 'worker_from_claim_mark_downloaded' "$APP_ROOT/scripts/download-from.sh"
grep -q 'MAX_BATCH=' "$APP_ROOT/scripts/download-from.sh"
grep -q 'bounded_rclone' "$APP_ROOT/scripts/download-from.sh"
grep -q 'listagem remota falhou/expirou' "$APP_ROOT/scripts/download-from.sh"

grep -q 'finalize_processing_claim' "$APP_ROOT/scripts/delete-from-watch.sh"
grep -q 'deletefile "$processing"' "$APP_ROOT/scripts/delete-from-watch.sh"
grep -q 'FILA FROM PRONTA IMEDIATAMENTE' "$APP_ROOT/scripts/delete-from-watch.sh"
grep -q 'DUPLICATA POR HASH REMOVIDA:' "$APP_ROOT/scripts/delete-from-watch.sh"
grep -q -- '--event close_write,moved_to' "$APP_ROOT/scripts/delete-from-watch.sh"

grep -q 'worker_from_claim_attach_archive' "$ROOT/scripts/dev-manager/70-imports.sh"
grep -q '^TimeoutStartSec=90s$' "$APP_ROOT/systemd/user/dev-automation-worker-from.service"
grep -q '^OnUnitInactiveSec=3s$' "$APP_ROOT/systemd/user/dev-automation-worker-from.timer"

echo 'worker-sync local test: OK'
