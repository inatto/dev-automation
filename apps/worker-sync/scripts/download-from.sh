#!/usr/bin/env bash
set -euo pipefail

REMOTE_DIR="${WORKER_REMOTE_FROM:-danielmaiax:worker/from}"
LOCAL_DIR="${WORKER_LOCAL_FROM:-/home/daniel/worker/from}"
RCLONE_BIN="${RCLONE_BIN:-/usr/bin/rclone}"

log() { printf '[worker-sync][from] [%s] %s\n' "$(date '+%F %T')" "$*"; }

mkdir -p "$LOCAL_DIR"
log "DOWNLOAD: $REMOTE_DIR -> $LOCAL_DIR"
"$RCLONE_BIN" copy \
  "$REMOTE_DIR" \
  "$LOCAL_DIR" \
  --create-empty-src-dirs \
  --log-level INFO
log "DOWNLOAD CONCLUÍDO"
