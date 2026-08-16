#!/usr/bin/env bash
set -euo pipefail

LOCAL_DIR="${WORKER_LOCAL_TO:-/home/daniel/worker/to}"
REMOTE_DIR="${WORKER_REMOTE_TO:-danielmaiax:worker/to}"
RCLONE_BIN="${RCLONE_BIN:-/usr/bin/rclone}"
INOTIFYWAIT_BIN="${INOTIFYWAIT_BIN:-/usr/bin/inotifywait}"
DEBOUNCE_SECONDS="${WORKER_UPLOAD_DEBOUNCE_SECONDS:-1}"

log() { printf '[worker-sync][to] [%s] %s\n' "$(date '+%F %T')" "$*"; }

mkdir -p "$LOCAL_DIR"

upload() {
  log "UPLOAD: $LOCAL_DIR -> $REMOTE_DIR"
  "$RCLONE_BIN" copy \
    "$LOCAL_DIR" \
    "$REMOTE_DIR" \
    --create-empty-src-dirs \
    --log-level INFO
  log "UPLOAD CONCLUÍDO"
}

# Garante envio de arquivos que já estavam em /to antes do login/restart.
upload

log "MONITORANDO ALTERAÇÕES LOCAIS: $LOCAL_DIR"
"$INOTIFYWAIT_BIN" \
  --monitor \
  --recursive \
  --quiet \
  --event close_write,create,moved_to \
  --format '%w%f' \
  "$LOCAL_DIR" |
while IFS= read -r changed; do
  log "ALTERAÇÃO LOCAL: $changed"
  sleep "$DEBOUNCE_SECONDS"
  upload
done
