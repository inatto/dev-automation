#!/usr/bin/env bash
# Worker REMOTO -> LOCAL da fila worker/from.
#
# Fluxo simples e literal:
#   Drive worker/from/<nome>.zip -> ~/worker/from/<mesmo-nome>.zip
#
# O arquivo remoto NÃO é renomeado e NÃO é movido para .processing.
# Depois que o dev-manager usar o ZIP, ele move o MESMO arquivo, com o MESMO
# nome, para ~/worker/from/backup. O worker de backup sobe esse mesmo nome para
# Drive worker/from/backup e então remove a origem de worker/from.
set -euo pipefail

REMOTE_DIR="${WORKER_REMOTE_FROM:-danielmaiax:worker/from}"
LOCAL_DIR="${WORKER_LOCAL_FROM:-/home/daniel/worker/from}"
LOCAL_INCOMING="$LOCAL_DIR/.incoming"
RCLONE_BIN="${RCLONE_BIN:-/usr/bin/rclone}"
TIMEOUT_BIN="${TIMEOUT_BIN:-/usr/bin/timeout}"
LIST_TIMEOUT="${WORKER_FROM_LIST_TIMEOUT:-15}"
DOWNLOAD_TIMEOUT="${WORKER_FROM_DOWNLOAD_TIMEOUT:-60}"
MAX_BATCH="${WORKER_FROM_MAX_BATCH:-8}"

log() { printf '[worker-sync][from] [%s] %s\n' "$(date '+%F %T')" "$*"; }

mkdir -p "$LOCAL_DIR" "$LOCAL_DIR/backup" "$LOCAL_INCOMING"

bounded_rclone() {
  local seconds="$1"; shift
  "$TIMEOUT_BIN" --signal=TERM --kill-after=5s "${seconds}s" \
    "$RCLONE_BIN" "$@" \
    --contimeout 10s --timeout 20s --retries 1 --low-level-retries 2 --log-level ERROR
}

remote_md5() {
  local remote_path="$1" line hash
  line="$(bounded_rclone "$LIST_TIMEOUT" md5sum "$remote_path" 2>/dev/null | head -n 1 || true)"
  hash="${line%%[[:space:]]*}"
  [[ "$hash" =~ ^[0-9a-fA-F]{32}$ ]] || return 1
  printf '%s\n' "${hash,,}"
}

download_one() {
  local name="$1" remote_source="$REMOTE_DIR/$name" staged="$LOCAL_INCOMING/$name.part"
  local local_target="$LOCAL_DIR/$name" backup_target="$LOCAL_DIR/backup/$name"
  local local_hash remote_hash

  [[ "${name,,}" == *.zip ]] || return 0
  [[ "$name" != */* ]] || return 0

  # Já está esperando o dev-manager ou já foi processado localmente. Não baixa
  # de novo. A remoção da origem remota acontece somente depois do backup subir.
  if [ -f "$local_target" ]; then
    log "AGUARDANDO USO LOCAL: $name"
    return 0
  fi
  if [ -f "$backup_target" ]; then
    log "JÁ PROCESSADO LOCALMENTE: $name (aguardando confirmação do backup remoto)"
    return 0
  fi

  rm -f -- "$staged"
  log "DOWNLOAD: $name"
  if ! bounded_rclone "$DOWNLOAD_TIMEOUT" copyto "$remote_source" "$staged"; then
    rm -f -- "$staged"
    log "AVISO - download falhou/expirou: $name"
    return 0
  fi

  local_hash="$(md5sum -- "$staged" | awk '{print tolower($1)}')"
  remote_hash="$(remote_md5 "$remote_source" || true)"
  if [ -n "$remote_hash" ] && [ "$remote_hash" != "$local_hash" ]; then
    rm -f -- "$staged"
    log "ERRO - hash divergiu; arquivo local descartado: $name"
    return 0
  fi

  # Revalida antes do publish para não sobrescrever algo que apareceu durante
  # o download. Sem nomes alternativos, sem sufixos automáticos.
  if [ -e "$local_target" ] || [ -e "$backup_target" ]; then
    rm -f -- "$staged"
    log "ADIADO - destino local já existe: $name"
    return 0
  fi

  mv -- "$staged" "$local_target"
  log "DOWNLOAD PUBLICADO: $name"
}

list_root_queue() {
  local listing count=0 name
  listing="$(mktemp)"
  trap 'rm -f -- "$listing"' RETURN

  if ! bounded_rclone "$LIST_TIMEOUT" lsf "$REMOTE_DIR" --files-only --max-depth 1 > "$listing"; then
    log "AVISO - listagem remota falhou/expirou em ${LIST_TIMEOUT}s."
    rm -f -- "$listing"
    trap - RETURN
    return 0
  fi

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [[ "${name,,}" == *.zip ]] || continue
    download_one "$name"
    count=$((count + 1))
    [ "$count" -lt "$MAX_BATCH" ] || break
  done < "$listing"

  rm -f -- "$listing"
  trap - RETURN
}

list_root_queue
