#!/usr/bin/env bash
# Contexto: Downloads local, saída de ZIPs, estabilidade, configuração e segurança


download_inbox_dir() {
  printf '%s\n' "${DOWNLOADS_DIR:-$HOME/Downloads}"
}

ensure_download_inbox() {
  local downloads
  downloads="$(download_inbox_dir)"
  [ -n "$downloads" ] || {
    echo "ERRO: pasta Downloads não pôde ser determinada." >&2
    return 1
  }
  mkdir -p -- "$downloads" || {
    echo "ERRO: não foi possível preparar Downloads: $downloads" >&2
    return 1
  }
}

archive_output_dir() {
  printf '%s\n' "$CODE_ROOT"
}

ensure_archive_output_dir() {
  local output_dir
  output_dir="$(archive_output_dir)"
  if [ -z "$output_dir" ] || [ ! -d "$output_dir" ]; then
    echo "ERRO: pasta de saída dos ZIPs não existe: ${output_dir:-<vazio>}" >&2
    return 1
  fi
}

stable_file() {
  local file="$1"
  local size_before
  local size_after

  [ -f "$file" ] || return 1

  size_before="$(stat -c %s "$file" 2>/dev/null || echo 0)"
  sleep "$STABLE_WAIT"

  [ -f "$file" ] || return 1

  size_after="$(stat -c %s "$file" 2>/dev/null || echo 0)"

  [ "$size_before" = "$size_after" ] &&
    [ "$size_before" -gt 0 ]
}

clean_file() {
  local file="$1"

  [ -f "$file" ] || return 0

  sed -E \
    -e 's/\r$//' \
    -e 's/^[[:space:]]+//' \
    -e 's/[[:space:]]+$//' \
    -e '/^$/d' \
    -e '/^#/d' \
    "$file"
}

ensure_files() {
  [ -f "$IGNORE_UNZIP_FILE" ] || touch "$IGNORE_UNZIP_FILE"

  if [ ! -f "$PROJECTS_FILE" ]; then
    echo "site-inst" > "$PROJECTS_FILE"
  fi
}

validate_backup_ignore_zip() {
  local required
  local -a active_rules=()
  local -a required_rules=(
    ".git/"
    ".venv/"
    "venv/"
    "node_modules/"
  )

  if [ ! -f "$IGNORE_ZIP_FILE" ]; then
    log "ERRO DE SEGURANÇA: ignore global de ZIP não existe: $IGNORE_ZIP_FILE"
    log "Backup bloqueado para evitar compactar dependências, ambientes virtuais e caches gigantes."
    return 1
  fi

  mapfile -t active_rules < <(clean_file "$IGNORE_ZIP_FILE")
  if [ "${#active_rules[@]}" -eq 0 ]; then
    log "ERRO DE SEGURANÇA: ignore global de ZIP está vazio: $IGNORE_ZIP_FILE"
    log "Backup bloqueado para evitar ZIPs gigantes."
    return 1
  fi

  for required in "${required_rules[@]}"; do
    if ! printf '%s\n' "${active_rules[@]}" | grep -Fxq -- "$required"; then
      log "ERRO DE SEGURANÇA: regra obrigatória ausente no ignore global de ZIP: $required"
      log "Arquivo: $IGNORE_ZIP_FILE"
      log "Backup bloqueado para evitar ZIPs gigantes."
      return 1
    fi
  done

  return 0
}

