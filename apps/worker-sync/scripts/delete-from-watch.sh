#!/usr/bin/env bash
# Esteira worker/from:
# quando um ZIP some da fila local após processamento, MOVE o original remoto
# para worker/from/backup em vez de apagá-lo. Nada de perder histórico.

LOCAL_DIR="${WORKER_LOCAL_FROM:-/home/daniel/worker/from}"
REMOTE_DIR="${WORKER_REMOTE_FROM:-danielmaiax:worker/from}"
RCLONE_BIN="${RCLONE_BIN:-/usr/bin/rclone}"
INOTIFYWAIT_BIN="${INOTIFYWAIT_BIN:-/usr/bin/inotifywait}"
LOCK_FILE="${WORKER_FROM_LOCK_FILE:-${XDG_RUNTIME_DIR:-/tmp}/dev-automation-worker-from.lock}"

log() { printf '[worker-sync][from-archive] [%s] %s\n' "$(date '+%F %T')" "$*"; }

archive_remote() {
  local removed="$1" rel base stem stamp remote_source remote_backup archive_name

  rel="${removed#"$LOCAL_DIR"/}"
  [ -n "$rel" ] || return 0

  # A fila é plana. backup/ é remoto e não deve ser manipulado pelo watcher.
  [[ "$rel" != */* ]] || {
    log "IGNORANDO subcaminho fora da fila raiz: $rel"
    return 0
  }

  base="$(basename -- "$rel")"
  [[ "${base,,}" == *.zip ]] || {
    log "IGNORANDO remoção não-ZIP: $base"
    return 0
  }

  stem="${base%.*}"
  stamp="${WORKER_ARCHIVE_STAMP:-$(date '+%Y%m%d-%H%M%S')}"
  archive_name="${stem}--${stamp}--PROCESSED.zip"
  remote_source="$REMOTE_DIR/$base"
  remote_backup="$REMOTE_DIR/backup/$archive_name"

  log "PROCESSADO LOCAL: $base"
  log "ARQUIVANDO REMOTO: $remote_source -> $remote_backup"

  "$RCLONE_BIN" mkdir "$REMOTE_DIR/backup" --log-level ERROR >/dev/null 2>&1 || true
  if "$RCLONE_BIN" moveto "$remote_source" "$remote_backup" --log-level ERROR; then
    log "OK - BACKUP REMOTO: $archive_name"
    return 0
  fi

  # Se outro processo já moveu/arquivou a origem, não converte isso em delete.
  log "AVISO - não foi possível mover a origem remota; arquivo NÃO foi apagado à força: $remote_source"
  return 0
}

mkdir -p "$LOCAL_DIR"
mkdir -p "$(dirname -- "$LOCK_FILE")"
log "MONITORANDO FILA PROCESSADA: $LOCAL_DIR"

"$INOTIFYWAIT_BIN" \
  --monitor \
  --quiet \
  --event delete,moved_from \
  --format '%e|%w%f' \
  "$LOCAL_DIR" |
while IFS='|' read -r events removed; do
  case ",$events," in
    *,ISDIR,*) continue ;;
  esac

  if command -v flock >/dev/null 2>&1; then
    (
      flock 9
      archive_remote "$removed"
    ) 9>"$LOCK_FILE"
  else
    archive_remote "$removed"
  fi
done
