#!/usr/bin/env bash
# Worker de backup da fila FROM.
#
# Fluxo único, sem renomear nada:
#   ~/worker/from/backup/<nome>.zip
#       -> Drive worker/from/backup/<mesmo-nome>.zip
#       -> remove Drive worker/from/<mesmo-nome>.zip após confirmar o mesmo MD5.
set -euo pipefail

LOCAL_DIR="${WORKER_LOCAL_FROM:-/home/daniel/worker/from}"
BACKUP_DIR="$LOCAL_DIR/backup"
REMOTE_DIR="${WORKER_REMOTE_FROM:-danielmaiax:worker/from}"
REMOTE_BACKUP="$REMOTE_DIR/backup"
RCLONE_BIN="${RCLONE_BIN:-/usr/bin/rclone}"
TIMEOUT_BIN="${TIMEOUT_BIN:-/usr/bin/timeout}"
INOTIFYWAIT_BIN="${INOTIFYWAIT_BIN:-/usr/bin/inotifywait}"
NETWORK_TIMEOUT="${WORKER_FROM_BACKUP_NETWORK_TIMEOUT:-90}"
LOCK_FILE="${WORKER_FROM_BACKUP_LOCK_FILE:-${XDG_RUNTIME_DIR:-/tmp}/dev-automation-worker-from-backup.lock}"

log() { printf '[worker-sync][from-backup] [%s] %s\n' "$(date '+%F %T')" "$*"; }

mkdir -p "$LOCAL_DIR" "$BACKUP_DIR" "$(dirname -- "$LOCK_FILE")"

bounded_rclone() {
  local seconds="$1"; shift
  "$TIMEOUT_BIN" --signal=TERM --kill-after=5s "${seconds}s" \
    "$RCLONE_BIN" "$@" \
    --contimeout 10s --timeout 20s --retries 1 --low-level-retries 2 --log-level ERROR
}

remote_md5() {
  local remote_path="$1" line hash
  line="$(bounded_rclone 20 md5sum "$remote_path" 2>/dev/null | head -n 1 || true)"
  hash="${line%%[[:space:]]*}"
  [[ "$hash" =~ ^[0-9a-fA-F]{32}$ ]] || return 1
  printf '%s\n' "${hash,,}"
}

remote_exact_exists() {
  local remote_path="$1" parent base listing rc
  parent="$(dirname -- "$remote_path")"
  base="$(basename -- "$remote_path")"
  set +e
  listing="$(bounded_rclone 15 lsf "$parent" --files-only --max-depth 1 2>/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || return 2
  printf '%s\n' "$listing" | grep -Fxq -- "$base"
}

publish_archive_unlocked() {
  local archive_path="$1" name remote_backup_target remote_source local_hash remote_source_hash remote_backup_hash exists_rc
  [ -f "$archive_path" ] || return 0
  name="$(basename -- "$archive_path")"
  [[ "${name,,}" == *.zip ]] || return 0

  remote_backup_target="$REMOTE_BACKUP/$name"
  remote_source="$REMOTE_DIR/$name"
  local_hash="$(md5sum -- "$archive_path" | awk '{print tolower($1)}')"

  log "UPLOAD BACKUP: $name"
  bounded_rclone 30 mkdir "$REMOTE_BACKUP" >/dev/null 2>&1 || true
  if ! bounded_rclone "$NETWORK_TIMEOUT" copyto "$archive_path" "$remote_backup_target"; then
    log "ERRO - upload do backup falhou/expirou: $name"
    return 1
  fi

  remote_backup_hash="$(remote_md5 "$remote_backup_target" || true)"
  if [ -n "$remote_backup_hash" ] && [ "$remote_backup_hash" != "$local_hash" ]; then
    log "ERRO - backup remoto divergiu após upload; origem preservada: $name"
    return 1
  fi

  # Só apaga a fila remota depois que o backup remoto do MESMO nome foi
  # confirmado. Se alguém reutilizar o mesmo nome para bytes diferentes, não
  # apagamos a versão nova por engano.
  set +e
  remote_exact_exists "$remote_source"
  exists_rc=$?
  set -e
  case "$exists_rc" in
    1)
      log "OK - BACKUP CONFIRMADO; origem já ausente: $name"
      return 0
      ;;
    2)
      log "AVISO - backup confirmado, mas não foi possível consultar a origem: $name"
      return 1
      ;;
  esac

  remote_source_hash="$(remote_md5 "$remote_source" || true)"
  if [ -n "$remote_source_hash" ] && [ "$remote_source_hash" != "$local_hash" ]; then
    log "ERRO - colisão de nome: Drive/from/$name tem conteúdo diferente; NÃO removido."
    return 1
  fi

  if bounded_rclone 30 deletefile "$remote_source" >/dev/null 2>&1; then
    log "OK - BACKUP CONFIRMADO E FILA REMOTA LIMPA: $name"
    return 0
  fi

  log "AVISO - backup confirmado, mas remoção da origem falhou: $name"
  return 1
}

publish_archive() {
  local archive_path="$1"
  if command -v flock >/dev/null 2>&1; then
    (
      flock 9
      publish_archive_unlocked "$archive_path"
    ) 9>"$LOCK_FILE"
  else
    publish_archive_unlocked "$archive_path"
  fi
}

catch_up() {
  local archive_path
  log "CATCH-UP BACKUP LOCAL -> DRIVE: $BACKUP_DIR"
  while IFS= read -r -d '' archive_path; do
    publish_archive "$archive_path" || true
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -iname '*.zip' -print0 2>/dev/null)
}

catch_up
log "MONITORANDO BACKUP LOCAL: $BACKUP_DIR"
"$INOTIFYWAIT_BIN" \
  --monitor \
  --quiet \
  --event close_write,moved_to \
  --format '%w%f' \
  "$BACKUP_DIR" |
while IFS= read -r changed; do
  [ -f "$changed" ] || continue
  [[ "${changed,,}" == *.zip ]] || continue
  publish_archive "$changed" || true
done
