#!/usr/bin/env bash
# Contexto: compactação de pastas SQL configuradas

expand_configured_path() {
  local configured_path="$1"

  configured_path="${configured_path/#\~\//$HOME/}"
  configured_path="${configured_path/#\$CODE_ROOT\//$CODE_ROOT/}"
  configured_path="${configured_path/#CODE_ROOT\//$CODE_ROOT/}"

  if [[ "$configured_path" != /* ]]; then
    configured_path="$CODE_ROOT/$configured_path"
  fi

  printf '%s\n' "$configured_path"
}

configured_sql_zip_folders() {
  local raw_line folder

  [ -f "$FOLDER_SQL_ZIP_FILE" ] || return 0

  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    raw_line="${raw_line%$'\r'}"
    raw_line="${raw_line%%#*}"
    raw_line="$(printf '%s' "$raw_line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$raw_line" ] || continue

    folder="$(expand_configured_path "$raw_line")"
    printf '%s\n' "$folder"
  done < "$FOLDER_SQL_ZIP_FILE"
}

zip_sql_folder() {
  local folder="$1"
  local stamp final_zip temp_dir temp_zip sql_file sql_name
  local -a sql_files=()
  local -a sql_names=()

  if [ ! -d "$folder" ]; then
    log "Pasta SQL ainda não existe: $folder"
    return 0
  fi

  while IFS= read -r -d '' sql_file; do
    if stable_file "$sql_file"; then
      sql_files+=("$sql_file")
    else
      log "SQL ainda está sendo gravado: $sql_file"
    fi
  done < <(
    find "$folder" \
      -maxdepth 1 \
      -type f \
      -iname '*.sql' \
      ! -name '*:Zone.Identifier' \
      -print0 2>/dev/null
  )

  [ "${#sql_files[@]}" -gt 0 ] || return 0

  taskbar_status zip "$(basename -- "$folder")"
  stamp="$(date '+%Y%m%d-%H%M')"
  final_zip="$folder/$stamp.zip"
  temp_dir="$(mktemp -d '/tmp/auto-code-folder-sql-zip-XXXXXX')"
  temp_zip="$temp_dir/$stamp.zip"

  if [ -f "$final_zip" ]; then
    if ! unzip -tq "$final_zip" >/dev/null 2>&1; then
      log "ERRO: ZIP existente inválido; SQLs mantidos: $final_zip"
      rm -rf -- "$temp_dir"
      return 1
    fi
    cp -f -- "$final_zip" "$temp_zip" || {
      log "ERRO: não foi possível preparar o ZIP existente: $final_zip"
      rm -rf -- "$temp_dir"
      return 1
    }
  fi

  for sql_file in "${sql_files[@]}"; do
    sql_name="$(basename -- "$sql_file")"
    sql_names+=("$sql_name")
    cp -f -- "$sql_file" "$temp_dir/$sql_name" || {
      log "ERRO: não foi possível preparar o SQL: $sql_file"
      rm -rf -- "$temp_dir"
      return 1
    }
  done

  (
    cd "$temp_dir" || exit 1
    zip -q "$temp_zip" -- "${sql_names[@]}"
  ) || {
    log "ERRO: falha ao gerar ZIP de SQLs em $folder; SQLs mantidos."
    rm -rf -- "$temp_dir"
    return 1
  }

  if [ ! -s "$temp_zip" ] || ! unzip -tq "$temp_zip" >/dev/null 2>&1; then
    log "ERRO: validação do ZIP de SQLs falhou; SQLs mantidos: $folder"
    rm -rf -- "$temp_dir"
    return 1
  fi

  if ! mv -f -- "$temp_zip" "$final_zip"; then
    log "ERRO: não foi possível instalar o ZIP final; SQLs mantidos: $final_zip"
    rm -rf -- "$temp_dir"
    return 1
  fi

  for sql_file in "${sql_files[@]}"; do
    if ! rm -f -- "$sql_file" || [ -e "$sql_file" ]; then
      log "ERRO: ZIP válido, mas o SQL não foi apagado: $sql_file"
      rm -rf -- "$temp_dir"
      return 1
    fi
  done

  rm -rf -- "$temp_dir"
  log "OK SQL ZIP: $final_zip (${#sql_files[@]} arquivo(s)); SQLs apagados."
  return 0
}

zip_configured_sql_folders() {
  local folder failed=0

  while IFS= read -r folder || [ -n "$folder" ]; do
    [ -n "$folder" ] || continue
    wait_if_paused
    zip_sql_folder "$folder" || failed=1
  done < <(configured_sql_zip_folders)

  return "$failed"
}

