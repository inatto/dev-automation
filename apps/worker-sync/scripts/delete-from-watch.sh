#!/usr/bin/env bash
# Worker de histórico da fila FROM.
#
# v2: o downloader já retirou o payload da raiz do Drive e o mantém em
# worker/from/.processing/<token>/<nome>. Quando o dev-manager arquiva o ZIP
# local, este worker sobe o histórico e apaga SOMENTE aquele caminho de
# .processing registrado no claim. Uma versão nova com o mesmo nome na raiz
# remota jamais é tocada.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/from-state.sh"

LOCAL_DIR="${WORKER_LOCAL_FROM:-/home/daniel/worker/from}"
BACKUP_DIR="$LOCAL_DIR/backup"
REMOTE_DIR="${WORKER_REMOTE_FROM:-danielmaiax:worker/from}"
REMOTE_BACKUP="$REMOTE_DIR/backup"
RCLONE_BIN="${RCLONE_BIN:-/usr/bin/rclone}"
TIMEOUT_BIN="${TIMEOUT_BIN:-/usr/bin/timeout}"
INOTIFYWAIT_BIN="${INOTIFYWAIT_BIN:-/usr/bin/inotifywait}"
BACKUP_LOCK_FILE="${WORKER_FROM_BACKUP_LOCK_FILE:-${XDG_RUNTIME_DIR:-/tmp}/dev-automation-worker-from-backup.lock}"
READY_FILE="$(worker_from_ready_file)"
NETWORK_TIMEOUT="${WORKER_FROM_BACKUP_NETWORK_TIMEOUT:-90}"
RECOVERY_MINUTES="${WORKER_FROM_RECOVERY_MINUTES:-30}"

log() { printf '[worker-sync][from-backup] [%s] %s\n' "$(date '+%F %T')" "$*"; }

bounded_rclone() {
  local seconds="$1"; shift
  "$TIMEOUT_BIN" --signal=TERM --kill-after=5s "${seconds}s" \
    "$RCLONE_BIN" "$@" \
    --contimeout 10s --timeout 20s --retries 1 --low-level-retries 2 --log-level ERROR
}

run_backup_locked() {
  if command -v flock >/dev/null 2>&1; then
    (
      flock 9
      "$@"
    ) 9>"$BACKUP_LOCK_FILE"
  else
    "$@"
  fi
}

original_name_from_archive() {
  local archive="$1" stem
  stem="${archive%.zip}"
  if [[ "$stem" =~ ^(.*)--[0-9]{8}-[0-9]{6}(-[0-9]+)?--(PROCESSED|FAILED)$ ]]; then
    printf '%s.zip\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

remote_md5_for_source() {
  local remote_source="$1" line hash
  line="$(bounded_rclone 20 md5sum "$remote_source" 2>/dev/null | head -n 1 || true)"
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

claim_md5_for_archive() {
  local original_name="$1" archive_name="$2" archive_path="$3" claim_path line1 line2 line3
  claim_path="$(worker_from_claim_path "$original_name")"
  if [ -f "$claim_path" ]; then
    line1="$(sed -n '1p' "$claim_path" 2>/dev/null || true)"
    line2="$(sed -n '2p' "$claim_path" 2>/dev/null || true)"
    line3="$(sed -n '3p' "$claim_path" 2>/dev/null || true)"
    if [ "$line1" = "$original_name" ] && [ "$line2" = "$archive_name" ] && [[ "$line3" =~ ^[0-9a-fA-F]{32}$ ]]; then
      printf '%s\n' "${line3,,}"
      return 0
    fi
  fi
  md5sum -- "$archive_path" | awk '{print tolower($1)}'
}

finalize_legacy_root() {
  # Compatibilidade com claims antigos criados antes de .processing.
  # Só apaga a raiz se o hash ainda for exatamente o payload arquivado.
  local archive_path="$1" archive_name="$2" original_name="$3" remote_source local_md5 remote_md5
  remote_source="$REMOTE_DIR/$original_name"
  local_md5="$(claim_md5_for_archive "$original_name" "$archive_name" "$archive_path")"
  remote_md5="$(remote_md5_for_source "$remote_source" || true)"

  if [ -z "$remote_md5" ]; then
    local exists_rc
    set +e
    remote_exact_exists "$remote_source"
    exists_rc=$?
    set -e
    if [ "$exists_rc" -eq 1 ]; then
      worker_from_claim_remove "$original_name"
      log "LEGACY: origem já não existe; claim liberado: $original_name"
      return 0
    fi
    log "AVISO - LEGACY sem hash remoto ou Drive indisponível; origem/claim preservados: $original_name"
    return 1
  fi

  if [ "$remote_md5" != "$local_md5" ]; then
    worker_from_claim_remove "$original_name"
    log "LEGACY: nova versão detectada na raiz; preservada: $original_name"
    return 0
  fi

  if bounded_rclone 30 deletefile "$remote_source" >/dev/null 2>&1; then
    worker_from_claim_remove "$original_name"
    log "LEGACY: origem antiga removida e claim liberado: $original_name"
    return 0
  fi
  log "AVISO - LEGACY: remoção remota falhou; claim mantido: $original_name"
  return 1
}

finalize_processing_claim() {
  local archive_path="$1" archive_name="$2" original_name="$3" claim_path processing parent
  claim_path="$(worker_from_claim_path "$original_name")"
  processing="$(sed -n '4p' "$claim_path" 2>/dev/null || true)"

  if [ -z "$processing" ]; then
    finalize_legacy_root "$archive_path" "$archive_name" "$original_name"
    return $?
  fi

  # O caminho é único por aquisição. A raiz remota pode já conter uma versão
  # nova com o mesmo nome e não participa desta operação.
  if bounded_rclone 30 deletefile "$processing" >/dev/null 2>&1; then
    parent="$(dirname -- "$processing")"
    bounded_rclone 15 rmdir "$parent" >/dev/null 2>&1 || true
    worker_from_claim_remove "$original_name"
    log "CLAIM FINALIZADO: removido .processing de $original_name; nome liberado para próxima versão."
    return 0
  fi

  # Se o arquivo de .processing já não existe, a operação é idempotentemente
  # concluída. Falha de rede, porém, NÃO é tratada como ausência.
  local exists_rc
  set +e
  remote_exact_exists "$processing"
  exists_rc=$?
  set -e
  if [ "$exists_rc" -eq 1 ]; then
    worker_from_claim_remove "$original_name"
    log "CLAIM FINALIZADO: .processing já estava ausente: $original_name"
    return 0
  fi

  log "AVISO - não foi possível remover/confirmar .processing; claim preservado: $original_name"
  return 1
}

publish_archive() {
  local archive_path="$1" archive_name original_name remote_target
  [ -f "$archive_path" ] || return 0
  archive_name="$(basename -- "$archive_path")"
  [[ "${archive_name,,}" == *.zip ]] || return 0
  original_name="$(original_name_from_archive "$archive_name" || true)"
  [ -n "$original_name" ] || return 0

  local had_claim=false
  if worker_from_claim_exists "$original_name"; then
    had_claim=true
    # Preserva processing_path registrado pelo downloader e anexa o histórico.
    worker_from_claim_attach_archive "$original_name" "$archive_name" "$archive_path" >/dev/null || true
  fi

  remote_target="$REMOTE_BACKUP/$archive_name"
  log "SUBINDO BACKUP LOCAL: $archive_name"
  bounded_rclone 30 mkdir "$REMOTE_BACKUP" >/dev/null 2>&1 || true
  if ! bounded_rclone "$NETWORK_TIMEOUT" copyto "$archive_path" "$remote_target"; then
    log "ERRO - upload do backup falhou/expirou; local e claim preservados: $archive_name"
    return 1
  fi

  log "OK - BACKUP LOCAL/DRIVE CONFIRMADO: $archive_name"
  if [ "$had_claim" = true ]; then
    finalize_processing_claim "$archive_path" "$archive_name" "$original_name"
  fi
}

recover_pending_archived_claims() {
  local claim original archive archive_path
  shopt -s nullglob
  for claim in "$(worker_from_pending_dir)"/*.claim; do
    original="$(sed -n '1p' "$claim" 2>/dev/null || true)"
    archive="$(sed -n '2p' "$claim" 2>/dev/null || true)"
    [ -n "$original" ] && [ -n "$archive" ] || continue
    archive_path="$BACKUP_DIR/$archive"
    [ -f "$archive_path" ] || continue
    log "RECUPERANDO BACKUP PENDENTE: $original"
    publish_archive "$archive_path" || true
  done
  shopt -u nullglob
}

recover_recent_preprocessing_legacy() {
  # Limpa o estrago das versões antigas: se há histórico recente sem claim e o
  # mesmo payload ainda está na raiz remota, cria um claim LEGACY e finaliza por
  # hash. Nunca apaga uma versão diferente com o mesmo nome.
  local row archive_path archive_name original_name local_md5 remote_md5
  local -A seen=()
  while IFS= read -r row; do
    archive_path="${row#* }"
    [ -f "$archive_path" ] || continue
    archive_name="$(basename -- "$archive_path")"
    original_name="$(original_name_from_archive "$archive_name" || true)"
    [ -n "$original_name" ] || continue
    [ -z "${seen[$original_name]+x}" ] || continue
    seen["$original_name"]=1
    worker_from_claim_exists "$original_name" && continue

    local_md5="$(md5sum -- "$archive_path" | awk '{print tolower($1)}')"
    remote_md5="$(remote_md5_for_source "$REMOTE_DIR/$original_name" || true)"
    [ -n "$remote_md5" ] && [ "$remote_md5" = "$local_md5" ] || continue

    worker_from_claim_attach_archive "$original_name" "$archive_name" "$archive_path" >/dev/null
    log "RECUPERAÇÃO LEGACY ANTI-LOOP: $original_name"
    finalize_legacy_root "$archive_path" "$archive_name" "$original_name" || true
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -iname '*--PROCESSED.zip' -mmin "-$RECOVERY_MINUTES" -printf '%T@ %p\n' 2>/dev/null | sort -nr)
}

reconcile_backups_bounded() {
  # Manutenção não bloqueia a fila FROM. Se Drive estiver lento, expira e o
  # próximo restart/tarefa tenta de novo. O histórico novo continua sendo
  # enviado individualmente pelo inotify.
  log "MANUTENÇÃO BACKUP: remoto -> local (limitada)."
  bounded_rclone "$NETWORK_TIMEOUT" mkdir "$REMOTE_BACKUP" >/dev/null 2>&1 || true
  bounded_rclone "$NETWORK_TIMEOUT" copy "$REMOTE_BACKUP" "$BACKUP_DIR" --create-empty-src-dirs || \
    log "AVISO - reconciliação remoto->local expirou/falhou; fila continua operacional."

  log "MANUTENÇÃO BACKUP: local -> remoto (limitada)."
  bounded_rclone "$NETWORK_TIMEOUT" copy "$BACKUP_DIR" "$REMOTE_BACKUP" --create-empty-src-dirs || \
    log "AVISO - reconciliação local->remoto expirou/falhou; fila continua operacional."
}

dedupe_processed_backups_by_md5() {
  local rows line hash rel base keep removed=0
  local -A keeper=()
  rows="$(mktemp)"
  trap 'rm -f -- "$rows"' RETURN

  if ! bounded_rclone "$NETWORK_TIMEOUT" md5sum "$REMOTE_BACKUP" 2>/dev/null \
      | awk 'NF >= 2 { h=$1; $1=""; sub(/^[[:space:]]+/, "", $0); print h "\t" $0 }' \
      | sort -t $'\t' -k2,2r > "$rows"; then
    log "AVISO - dedupe por hash não concluiu; será tentado depois."
    rm -f -- "$rows"
    trap - RETURN
    return 0
  fi

  while IFS=$'\t' read -r hash rel; do
    [[ "$hash" =~ ^[0-9a-fA-F]{32}$ ]] || continue
    base="$(basename -- "$rel")"
    case "$base" in *--PROCESSED.zip) ;; *) continue ;; esac
    hash="${hash,,}"
    if [[ -z "${keeper[$hash]+x}" ]]; then
      keeper["$hash"]="$rel"
      continue
    fi
    keep="${keeper[$hash]}"
    if bounded_rclone 30 deletefile "$REMOTE_BACKUP/$rel" >/dev/null 2>&1; then
      rm -f -- "$BACKUP_DIR/$rel"
      removed=$((removed + 1))
      log "DUPLICATA POR HASH REMOVIDA: $base (igual a $(basename -- "$keep"))"
    fi
  done < "$rows"
  log "DEDUP BACKUP POR HASH: $removed duplicata(s) removida(s)."
  rm -f -- "$rows"
  trap - RETURN
}

publish_recent_local_archives() {
  local archive_path
  while IFS= read -r -d '' archive_path; do
    publish_archive "$archive_path" || true
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -iname '*--PROCESSED.zip' -mmin -10 -print0 2>/dev/null)
}

maintenance() {
  run_backup_locked recover_pending_archived_claims
  run_backup_locked recover_recent_preprocessing_legacy
  run_backup_locked reconcile_backups_bounded
  run_backup_locked publish_recent_local_archives
  run_backup_locked dedupe_processed_backups_by_md5
}

mkdir -p "$LOCAL_DIR" "$BACKUP_DIR" "$(worker_from_pending_dir)" "$(dirname -- "$READY_FILE")" "$(dirname -- "$BACKUP_LOCK_FILE")"
: > "$READY_FILE"
log "FILA FROM PRONTA IMEDIATAMENTE: manutenção de backup não bloqueia downloader."

# Manutenção pesada em paralelo. Ela possui lock próprio e nunca segura o lock
# curto usado pelo downloader para publicar arquivos locais.
maintenance &
maintenance_pid=$!

cleanup() {
  kill "$maintenance_pid" 2>/dev/null || true
  wait "$maintenance_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log "MONITORANDO BACKUP LOCAL: $BACKUP_DIR"
"$INOTIFYWAIT_BIN" \
  --monitor \
  --quiet \
  --event close_write,moved_to \
  --format '%e|%w%f' \
  "$BACKUP_DIR" |
while IFS='|' read -r events archive_path; do
  case ",$events," in *,ISDIR,*) continue ;; esac
  run_backup_locked publish_archive "$archive_path" || true
done
