#!/usr/bin/env bash
# Contexto: Downloads local, saída de ZIPs, estabilidade, configuração e segurança


download_inbox_dir() {
  # Compatibilidade: este nome continua representando a caixa principal Linux.
  printf '%s\n' "${DOWNLOADS_DIR:-$HOME/Downloads}"
}

windows_download_inbox_dir() {
  printf '%s\n' "${WINDOWS_DOWNLOADS_DIR:-/mnt/c/Users/daniel/Downloads}"
}

download_inbox_dirs() {
  local primary windows
  primary="$(download_inbox_dir)"
  [ -n "$primary" ] && printf '%s\n' "$primary"

  if is_wsl_runtime; then
    windows="$(windows_download_inbox_dir)"
    if [ -n "$windows" ] && [ "$windows" != "$primary" ]; then
      printf '%s\n' "$windows"
    fi
  fi
}

download_inbox_existing_dirs() {
  local dir
  while IFS= read -r dir || [ -n "$dir" ]; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] && printf '%s\n' "$dir"
  done < <(download_inbox_dirs)
}

download_inbox_summary() {
  local dir summary=""
  while IFS= read -r dir || [ -n "$dir" ]; do
    [ -n "$dir" ] || continue
    if [ -z "$summary" ]; then
      summary="$dir"
    else
      summary="$summary + $dir"
    fi
  done < <(download_inbox_dirs)
  printf '%s\n' "$summary"
}

ensure_download_inbox() {
  local primary dir parent
  primary="$(download_inbox_dir)"
  [ -n "$primary" ] || {
    echo "ERRO: pasta Downloads não pôde ser determinada." >&2
    return 1
  }

  mkdir -p -- "$primary" || {
    echo "ERRO: não foi possível preparar Downloads: $primary" >&2
    return 1
  }

  # Em WSL, acompanha também o Downloads do Windows. Não criamos uma árvore
  # /mnt/c falsa se a unidade/perfil não estiver montado; nesse caso o Linux
  # continua funcionando e o diretório passa a ser usado quando existir.
  if is_wsl_runtime; then
    dir="$(windows_download_inbox_dir)"
    if [ -n "$dir" ] && [ "$dir" != "$primary" ]; then
      parent="$(dirname -- "$dir")"
      if [ -d "$parent" ]; then
        mkdir -p -- "$dir" || {
          echo "AVISO: não foi possível preparar Downloads do Windows: $dir" >&2
        }
      fi
    fi
  fi
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

