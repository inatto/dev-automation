#!/usr/bin/env bash

LOCAL_DIR="${WORKER_LOCAL_TO:-/home/daniel/worker/to}"
REMOTE_DIR="${WORKER_REMOTE_TO:-danielmaiax:worker/to}"
RCLONE_BIN="${RCLONE_BIN:-/usr/bin/rclone}"
INOTIFYWAIT_BIN="${INOTIFYWAIT_BIN:-/usr/bin/inotifywait}"

log() { printf '[worker-sync][to] [%s] %s\n' "$(date '+%F %T')" "$*"; }

mkdir -p "$LOCAL_DIR"

# Catch-up único no start: envia o que já existia antes do watcher subir.
log "CATCH-UP INICIAL: $LOCAL_DIR -> $REMOTE_DIR"
"$RCLONE_BIN" copy \
  "$LOCAL_DIR" \
  "$REMOTE_DIR" \
  --create-empty-src-dirs \
  --log-level ERROR || log "AVISO: catch-up inicial falhou; watcher continuará ativo"

log "MONITORANDO: $LOCAL_DIR"
"$INOTIFYWAIT_BIN" \
  --monitor \
  --recursive \
  --quiet \
  --event close_write,moved_to \
  --format '%w%f' \
  "$LOCAL_DIR" |
while IFS= read -r changed; do
  [ -f "$changed" ] || continue
  rel="${changed#"$LOCAL_DIR"/}"
  dest="$REMOTE_DIR/$rel"
  log "UPLOAD: $changed -> $dest"
  start="$(date +%s)"
  if "$RCLONE_BIN" copyto "$changed" "$dest" --no-traverse --log-level ERROR; then
    elapsed=$(( $(date +%s) - start ))
    log "OK - UPLOAD CONCLUÍDO EM ${elapsed}s"
  else
    log "ERRO - UPLOAD: $changed"
  fi
done
