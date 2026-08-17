#!/usr/bin/env bash
# Esteira worker/from:
# 1) dev-manager MOVE o ZIP processado da raiz local para local/backup;
# 2) este watcher sobe esse MESMO arquivo para Drive/from/backup;
# 3) só depois remove o original da fila remota.
# No start, reconcilia o histórico nos dois sentidos sem apagar histórico.
set -euo pipefail

LOCAL_DIR="${WORKER_LOCAL_FROM:-/home/daniel/worker/from}"
BACKUP_DIR="$LOCAL_DIR/backup"
REMOTE_DIR="${WORKER_REMOTE_FROM:-danielmaiax:worker/from}"
REMOTE_BACKUP="$REMOTE_DIR/backup"
RCLONE_BIN="${RCLONE_BIN:-/usr/bin/rclone}"
INOTIFYWAIT_BIN="${INOTIFYWAIT_BIN:-/usr/bin/inotifywait}"
LOCK_FILE="${WORKER_FROM_LOCK_FILE:-${XDG_RUNTIME_DIR:-/tmp}/dev-automation-worker-from.lock}"

log() { printf '[worker-sync][from-backup] [%s] %s\n' "$(date '+%F %T')" "$*"; }

original_name_from_archive() {
  local archive="$1" stem
  stem="${archive%.zip}"
  if [[ "$stem" =~ ^(.*)--[0-9]{8}-[0-9]{6}(-[0-9]+)?--(PROCESSED|FAILED)$ ]]; then
    printf '%s.zip\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

reconcile_backups() {
  log "RECONCILIANDO BACKUP: remoto -> local"
  "$RCLONE_BIN" mkdir "$REMOTE_BACKUP" --log-level ERROR >/dev/null 2>&1 || true
  "$RCLONE_BIN" copy "$REMOTE_BACKUP" "$BACKUP_DIR" --create-empty-src-dirs --log-level INFO

  log "RECONCILIANDO BACKUP: local -> remoto"
  "$RCLONE_BIN" copy "$BACKUP_DIR" "$REMOTE_BACKUP" --create-empty-src-dirs --log-level INFO
  log "BACKUP RECONCILIADO"
}

publish_archive() {
  local archive_path="$1" archive_name original_name remote_source remote_target
  [ -f "$archive_path" ] || return 0

  archive_name="$(basename -- "$archive_path")"
  [[ "${archive_name,,}" == *.zip ]] || return 0
  original_name="$(original_name_from_archive "$archive_name" || true)"
  [ -n "$original_name" ] || {
    log "IGNORANDO arquivo sem padrão de histórico: $archive_name"
    return 0
  }

  remote_source="$REMOTE_DIR/$original_name"
  remote_target="$REMOTE_BACKUP/$archive_name"

  log "SUBINDO BACKUP LOCAL: $archive_name"
  "$RCLONE_BIN" mkdir "$REMOTE_BACKUP" --log-level ERROR >/dev/null 2>&1 || true
  if ! "$RCLONE_BIN" copyto "$archive_path" "$remote_target" --log-level ERROR; then
    log "ERRO - backup remoto não confirmado; fila remota preservada: $original_name"
    return 1
  fi

  log "OK - BACKUP LOCAL/DRIVE CONFIRMADO: $archive_name"
  if "$RCLONE_BIN" deletefile "$remote_source" --log-level ERROR >/dev/null 2>&1; then
    log "FILA REMOTA LIMPA: $original_name"
  else
    # Pode já ter sido removido em uma rodada anterior. Não apaga o backup.
    log "AVISO - origem remota já não existe ou não pôde ser removida: $original_name"
  fi
}

mkdir -p "$LOCAL_DIR" "$BACKUP_DIR"
mkdir -p "$(dirname -- "$LOCK_FILE")"

run_locked() {
  if command -v flock >/dev/null 2>&1; then
    (
      flock 9
      "$@"
    ) 9>"$LOCK_FILE"
  else
    "$@"
  fi
}

run_locked reconcile_backups
log "MONITORANDO BACKUP LOCAL: $BACKUP_DIR"

"$INOTIFYWAIT_BIN" \
  --monitor \
  --quiet \
  --event close_write,moved_to \
  --format '%e|%w%f' \
  "$BACKUP_DIR" |
while IFS='|' read -r events archive_path; do
  case ",$events," in
    *,ISDIR,*) continue ;;
  esac
  run_locked publish_archive "$archive_path" || true
done
