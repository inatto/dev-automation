#!/usr/bin/env bash
# Somente REMOTO -> LOCAL para a fila raiz.
# backup/ não entra na fila; o serviço from-backup reconcilia o histórico no
# start e publica cada novo ZIP arquivado localmente.
set -euo pipefail

REMOTE_DIR="${WORKER_REMOTE_FROM:-danielmaiax:worker/from}"
LOCAL_DIR="${WORKER_LOCAL_FROM:-/home/daniel/worker/from}"
RCLONE_BIN="${RCLONE_BIN:-/usr/bin/rclone}"
LOCK_FILE="${WORKER_FROM_LOCK_FILE:-${XDG_RUNTIME_DIR:-/tmp}/dev-automation-worker-from.lock}"

log() { printf '[worker-sync][from] [%s] %s\n' "$(date '+%F %T')" "$*"; }

mkdir -p "$LOCAL_DIR/backup"
mkdir -p "$(dirname -- "$LOCK_FILE")"
log "DOWNLOAD FILA: $REMOTE_DIR -> $LOCAL_DIR (backup excluído da fila)"

run_download() {
  "$RCLONE_BIN" copy \
    "$REMOTE_DIR" \
    "$LOCAL_DIR" \
    --exclude '/backup/**' \
    --exclude '/backup/' \
    --create-empty-src-dirs \
    --log-level INFO
}

if command -v flock >/dev/null 2>&1; then
  (
    flock 9
    run_download
  ) 9>"$LOCK_FILE"
else
  run_download
fi

log "DOWNLOAD CONCLUÍDO"
