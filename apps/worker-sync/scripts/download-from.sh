#!/usr/bin/env bash
# Worker REMOTO -> LOCAL da fila worker/from.
#
# Arquitetura v2: o arquivo é primeiro MOVIDO server-side da raiz remota para
# .processing/<token>/<nome>. Só depois é baixado para staging local e publicado
# por rename atômico na raiz local. A raiz do Drive, portanto, deixa de conter o
# payload antes que o dev-manager possa começar a processá-lo. Isso elimina a
# corrida "moveu local para backup e o downloader trouxe o mesmo remoto de novo".
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/from-state.sh"

REMOTE_DIR="${WORKER_REMOTE_FROM:-danielmaiax:worker/from}"
REMOTE_PROCESSING="$REMOTE_DIR/.processing"
LOCAL_DIR="${WORKER_LOCAL_FROM:-/home/daniel/worker/from}"
LOCAL_INCOMING="$LOCAL_DIR/.incoming"
RCLONE_BIN="${RCLONE_BIN:-/usr/bin/rclone}"
TIMEOUT_BIN="${TIMEOUT_BIN:-/usr/bin/timeout}"
LOCK_FILE="${WORKER_FROM_LOCK_FILE:-${XDG_RUNTIME_DIR:-/tmp}/dev-automation-worker-from.lock}"
LIST_TIMEOUT="${WORKER_FROM_LIST_TIMEOUT:-15}"
MOVE_TIMEOUT="${WORKER_FROM_MOVE_TIMEOUT:-30}"
DOWNLOAD_TIMEOUT="${WORKER_FROM_DOWNLOAD_TIMEOUT:-60}"
MAX_BATCH="${WORKER_FROM_MAX_BATCH:-8}"
STALE_CLAIM_SECONDS="${WORKER_FROM_STALE_CLAIM_SECONDS:-600}"

log() { printf '[worker-sync][from] [%s] %s\n' "$(date '+%F %T')" "$*"; }

mkdir -p "$LOCAL_DIR/backup" "$LOCAL_INCOMING" "$(worker_from_pending_dir)" "$(dirname -- "$LOCK_FILE")"

bounded_rclone() {
  local seconds="$1"; shift
  "$TIMEOUT_BIN" --signal=TERM --kill-after=5s "${seconds}s" \
    "$RCLONE_BIN" "$@" \
    --contimeout 10s --timeout 20s --retries 1 --low-level-retries 2 --log-level ERROR
}

remote_file_exists() {
  local remote_path="$1" parent base listing rc
  parent="$(dirname -- "$remote_path")"
  base="$(basename -- "$remote_path")"
  set +e
  listing="$(bounded_rclone "$LIST_TIMEOUT" lsf "$parent" --files-only --max-depth 1 2>/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || return 2
  printf '%s\n' "$listing" | grep -Fxq -- "$base"
}

remote_md5() {
  local remote_path="$1" line hash
  line="$(bounded_rclone "$LIST_TIMEOUT" md5sum "$remote_path" 2>/dev/null | head -n 1 || true)"
  hash="${line%%[[:space:]]*}"
  [[ "$hash" =~ ^[0-9a-fA-F]{32}$ ]] || return 1
  printf '%s\n' "${hash,,}"
}

claim_locked() {
  local original="$1" processing="$2"
  if command -v flock >/dev/null 2>&1; then
    (
      flock 9
      if worker_from_claim_exists "$original" || [ -e "$LOCAL_DIR/$original" ]; then
        return 1
      fi
      worker_from_claim_prepare "$original" "$processing" >/dev/null
    ) 9>"$LOCK_FILE"
  else
    if worker_from_claim_exists "$original" || [ -e "$LOCAL_DIR/$original" ]; then
      return 1
    fi
    worker_from_claim_prepare "$original" "$processing" >/dev/null
  fi
}

publish_local() {
  local original="$1" staged="$2" local_target="$LOCAL_DIR/$original" staged_md5 existing_md5
  staged_md5="$(md5sum -- "$staged" | awk '{print tolower($1)}')"

  if command -v flock >/dev/null 2>&1; then
    (
      flock 9
      if [ -e "$local_target" ]; then
        if [ -f "$local_target" ]; then
          existing_md5="$(md5sum -- "$local_target" | awk '{print tolower($1)}')"
          if [ "$existing_md5" = "$staged_md5" ]; then
            rm -f -- "$staged"
            worker_from_claim_mark_downloaded "$original" "$staged_md5"
            return 0
          fi
        fi
        return 2
      fi
      worker_from_claim_mark_downloaded "$original" "$staged_md5"
      mv -- "$staged" "$local_target"
    ) 9>"$LOCK_FILE"
  else
    [ ! -e "$local_target" ] || return 2
    worker_from_claim_mark_downloaded "$original" "$staged_md5"
    mv -- "$staged" "$local_target"
  fi
}

resume_claim() {
  local claim="$1" original processing archive staged token local_md5 remote_hash rc created now
  original="$(sed -n '1p' "$claim" 2>/dev/null || true)"
  archive="$(sed -n '2p' "$claim" 2>/dev/null || true)"
  processing="$(sed -n '4p' "$claim" 2>/dev/null || true)"
  created="$(sed -n '6p' "$claim" 2>/dev/null || true)"
  [ -n "$original" ] || return 0

  # Já publicado localmente ou já arquivado: o dev-manager/backup worker assume.
  [ -z "$archive" ] || return 0
  [ ! -f "$LOCAL_DIR/$original" ] || return 0

  # Claim legado sem .processing não é responsabilidade do downloader v2.
  [ -n "$processing" ] || return 0
  token="$(basename -- "$(dirname -- "$processing")")"
  staged="$LOCAL_INCOMING/$token/$original.part"
  mkdir -p -- "$(dirname -- "$staged")"

  set +e
  remote_file_exists "$processing"
  rc=$?
  set -e
  if [ "$rc" -eq 2 ]; then
    log "AVISO - não foi possível consultar .processing de $original; claim preservado."
    return 0
  fi
  if [ "$rc" -eq 1 ]; then
    # Se ainda está na raiz, a aquisição caiu antes/depois do moveto. Tenta de
    # novo de forma idempotente. Se não existe em nenhum lado por muito tempo,
    # libera claim órfão para não bloquear para sempre um nome futuro.
    set +e
    remote_file_exists "$REMOTE_DIR/$original"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      log "RETOMANDO CLAIM: movendo $original para área transacional remota."
      if ! bounded_rclone "$MOVE_TIMEOUT" mkdir "$(dirname -- "$processing")" >/dev/null 2>&1 || \
         ! bounded_rclone "$MOVE_TIMEOUT" moveto "$REMOTE_DIR/$original" "$processing"; then
        log "AVISO - claim de $original ainda não conseguiu mover a origem; nova tentativa virá no próximo ciclo."
        return 0
      fi
    elif [ "$rc" -eq 2 ]; then
      log "AVISO - não foi possível consultar raiz remota para $original; claim preservado."
      return 0
    else
      now="$(date +%s)"
      [[ "$created" =~ ^[0-9]+$ ]] || created="$now"
      if [ $((now - created)) -ge "$STALE_CLAIM_SECONDS" ]; then
        worker_from_claim_remove "$original"
        rm -rf -- "$(dirname -- "$staged")"
        log "CLAIM ÓRFÃO EXPIRADO: $original"
      fi
      return 0
    fi
  fi

  log "BAIXANDO CLAIM: $original"
  rm -f -- "$staged"
  if ! bounded_rclone "$DOWNLOAD_TIMEOUT" copyto "$processing" "$staged"; then
    rm -f -- "$staged"
    log "AVISO - download de $original falhou/expirou; claim preservado para retomada."
    return 0
  fi

  local_md5="$(md5sum -- "$staged" | awk '{print tolower($1)}')"
  remote_hash="$(remote_md5 "$processing" || true)"
  if [ -n "$remote_hash" ] && [ "$remote_hash" != "$local_md5" ]; then
    rm -f -- "$staged"
    log "ERRO - hash divergiu para $original; staging descartado e remoto preservado."
    return 0
  fi

  set +e
  publish_local "$original" "$staged"
  rc=$?
  set -e
  case "$rc" in
    0)
      log "DOWNLOAD PUBLICADO: $original (claim remoto preservado até o backup confirmar)."
      ;;
    2)
      log "ADIADO: $original já possui outra versão na raiz local; claim fica em staging para próxima rodada."
      ;;
    *)
      log "AVISO - falha ao publicar $original; será retomado."
      ;;
  esac
}

recover_claims() {
  local claim
  shopt -s nullglob
  for claim in "$(worker_from_pending_dir)"/*.claim; do
    resume_claim "$claim"
  done
  shopt -u nullglob
}

recover_remote_processing_without_claim() {
  local listing rel original processing claim_path token
  listing="$(mktemp)"
  trap 'rm -f -- "$listing"' RETURN
  if ! bounded_rclone "$LIST_TIMEOUT" lsf "$REMOTE_PROCESSING" --files-only --recursive > "$listing" 2>/dev/null; then
    rm -f -- "$listing"
    trap - RETURN
    return 0
  fi
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    original="$(basename -- "$rel")"
    [[ "${original,,}" == *.zip ]] || continue
    worker_from_claim_exists "$original" && continue
    processing="$REMOTE_PROCESSING/$rel"
    token="$(basename -- "$(dirname -- "$rel")")"
    if claim_locked "$original" "$processing"; then
      log "RECUPERAÇÃO: .processing sem claim reconstruído para $original ($token)."
    fi
  done < "$listing"
  rm -f -- "$listing"
  trap - RETURN
}

claim_root_file() {
  local original="$1" token processing
  [[ "${original,,}" == *.zip ]] || return 0
  [[ "$original" != */* ]] || return 0
  worker_from_claim_exists "$original" && return 0
  [ ! -e "$LOCAL_DIR/$original" ] || return 0

  token="$(date +%s%N)-$$-$RANDOM"
  processing="$REMOTE_PROCESSING/$token/$original"
  claim_locked "$original" "$processing" || return 0
  log "CLAIM REMOTO: $original -> .processing/$token/"

  if ! bounded_rclone "$MOVE_TIMEOUT" mkdir "$REMOTE_PROCESSING/$token" >/dev/null 2>&1 || \
     ! bounded_rclone "$MOVE_TIMEOUT" moveto "$REMOTE_DIR/$original" "$processing"; then
    # Não remove o claim às cegas: o moveto pode ter concluído no servidor e a
    # resposta ter expirado. resume_claim() verifica ambos os lados no próximo ciclo.
    log "AVISO - moveto de $original não confirmou; claim preservado para recuperação idempotente."
    return 0
  fi

  resume_claim "$(worker_from_claim_path "$original")"
}

list_root_queue() {
  local listing count=0 original
  listing="$(mktemp)"
  trap 'rm -f -- "$listing"' RETURN
  if ! bounded_rclone "$LIST_TIMEOUT" lsf "$REMOTE_DIR" --files-only --max-depth 1 > "$listing"; then
    log "AVISO - listagem remota falhou/expirou em ${LIST_TIMEOUT}s; rodada encerrada sem travar o worker."
    rm -f -- "$listing"
    trap - RETURN
    return 0
  fi

  while IFS= read -r original; do
    [ -n "$original" ] || continue
    [[ "${original,,}" == *.zip ]] || continue
    [[ "$original" != */* ]] || continue
    claim_root_file "$original"
    count=$((count + 1))
    [ "$count" -lt "$MAX_BATCH" ] || break
  done < "$listing"
  rm -f -- "$listing"
  trap - RETURN
}

log "RODADA FROM: recuperação -> claim remoto -> download por arquivo (máx. $MAX_BATCH)."
recover_remote_processing_without_claim
recover_claims
list_root_queue
log "RODADA FROM CONCLUÍDA"
