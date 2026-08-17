#!/usr/bin/env bash
# Estado transacional compartilhado da fila worker/from.
#
# Claim v2 (6 linhas):
#   1 original_name
#   2 archive_name (vazio enquanto ainda está na fila local)
#   3 md5 do payload (vazio até o download/arquivamento confirmar)
#   4 remote_processing_path (vazio para claims legados)
#   5 state: CLAIMING|DOWNLOADED|ARCHIVED|LEGACY
#   6 created_epoch
#
# O claim nasce ANTES do arquivo sair da raiz remota. Assim o mesmo nome nunca
# pode ser adquirido duas vezes em paralelo, mesmo se o dev-manager mover o ZIP
# local enquanto uma rodada do downloader já estiver em andamento.

worker_sync_state_dir() {
  printf '%s\n' "${WORKER_SYNC_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dev-automation/worker-sync}"
}

worker_from_pending_dir() {
  printf '%s/from-pending\n' "$(worker_sync_state_dir)"
}

worker_from_ready_file() {
  printf '%s/from-backup.ready\n' "$(worker_sync_state_dir)"
}

worker_from_claim_id() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

worker_from_claim_path() {
  local original_name="$1"
  printf '%s/%s.claim\n' "$(worker_from_pending_dir)" "$(worker_from_claim_id "$original_name")"
}

_worker_from_claim_write_fields() {
  local claim_path="$1" original_name="$2" archive_name="$3" md5="$4" processing_path="$5" state="$6" created="$7"
  local tmp
  mkdir -p -- "$(dirname -- "$claim_path")"
  tmp="${claim_path}.tmp.$$.$RANDOM"
  {
    printf '%s\n' "$original_name"
    printf '%s\n' "$archive_name"
    printf '%s\n' "$md5"
    printf '%s\n' "$processing_path"
    printf '%s\n' "$state"
    printf '%s\n' "$created"
  } > "$tmp"
  mv -f -- "$tmp" "$claim_path"
}

worker_from_claim_field() {
  local original_name="$1" line="$2" claim_path
  claim_path="$(worker_from_claim_path "$original_name")"
  [ -f "$claim_path" ] || return 1
  sed -n "${line}p" "$claim_path"
}

worker_from_claim_prepare() {
  local original_name="$1" processing_path="$2" claim_path created
  claim_path="$(worker_from_claim_path "$original_name")"
  created="$(date +%s)"
  if [ -f "$claim_path" ]; then
    printf '%s\n' "$claim_path"
    return 0
  fi
  _worker_from_claim_write_fields "$claim_path" "$original_name" "" "" "$processing_path" "CLAIMING" "$created"
  printf '%s\n' "$claim_path"
}

worker_from_claim_mark_downloaded() {
  local original_name="$1" md5="$2" claim_path archive processing state created
  claim_path="$(worker_from_claim_path "$original_name")"
  [ -f "$claim_path" ] || return 1
  archive="$(sed -n '2p' "$claim_path" 2>/dev/null || true)"
  processing="$(sed -n '4p' "$claim_path" 2>/dev/null || true)"
  created="$(sed -n '6p' "$claim_path" 2>/dev/null || true)"
  [ -n "$created" ] || created="$(date +%s)"
  state="DOWNLOADED"
  _worker_from_claim_write_fields "$claim_path" "$original_name" "$archive" "$md5" "$processing" "$state" "$created"
}

worker_from_claim_attach_archive() {
  local original_name="$1" archive_name="$2" source_file="${3:-}" claim_path md5 processing created
  claim_path="$(worker_from_claim_path "$original_name")"
  md5=""
  processing=""
  created="$(date +%s)"

  if [ -f "$claim_path" ]; then
    md5="$(sed -n '3p' "$claim_path" 2>/dev/null || true)"
    processing="$(sed -n '4p' "$claim_path" 2>/dev/null || true)"
    created="$(sed -n '6p' "$claim_path" 2>/dev/null || true)"
    [ -n "$created" ] || created="$(date +%s)"
  fi
  if [ -z "$md5" ] && [ -n "$source_file" ] && [ -f "$source_file" ]; then
    md5="$(md5sum -- "$source_file" | awk '{print tolower($1)}')"
  fi

  _worker_from_claim_write_fields "$claim_path" "$original_name" "$archive_name" "$md5" "$processing" "ARCHIVED" "$created"
  printf '%s\n' "$claim_path"
}

# Compatibilidade para chamadas antigas. Se já existe claim v2, preserva o
# caminho remoto em .processing e apenas anexa o nome do arquivo de backup.
worker_from_claim_write() {
  local original_name="$1" archive_name="$2" source_file="${3:-}"
  worker_from_claim_attach_archive "$original_name" "$archive_name" "$source_file"
}

worker_from_claim_read() {
  local claim_path="$1"
  [ -f "$claim_path" ] || return 1
  sed -n '1p;2p;3p;4p;5p;6p' "$claim_path"
}

worker_from_claim_remove() {
  local original_name="$1"
  rm -f -- "$(worker_from_claim_path "$original_name")"
}

worker_from_claim_exists() {
  local original_name="$1"
  [ -f "$(worker_from_claim_path "$original_name")" ]
}
