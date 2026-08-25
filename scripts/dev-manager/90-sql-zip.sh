#!/usr/bin/env bash
# Contexto: compactação manual de SQL e snapshots automáticos não destrutivos

expand_configured_path() {
  local configured_path="$1"

  configured_path="${configured_path/#\~\//$HOME/}"
  configured_path="${configured_path/#\$CODE_ROOT\//$CODE_ROOT/}"
  configured_path="${configured_path/#CODE_ROOT\//$CODE_ROOT/}"

  if [[ "$configured_path" != /* ]]; then
    configured_path="$CODE_ROOT/$configured_path"
  fi

  # Remove somente barras finais redundantes para comparações de path.
  while [[ "$configured_path" != "/" && "$configured_path" == */ ]]; do
    configured_path="${configured_path%/}"
  done

  printf '%s\n' "$configured_path"
}

configured_paths_from_file() {
  local config_file="$1"
  local raw_line folder

  [ -f "$config_file" ] || return 0

  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    raw_line="${raw_line%$'\r'}"
    raw_line="${raw_line%%#*}"
    raw_line="$(printf '%s' "$raw_line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$raw_line" ] || continue

    folder="$(expand_configured_path "$raw_line")"
    printf '%s\n' "$folder"
  done < "$config_file"
}

configured_sql_zip_folders() {
  configured_paths_from_file "$FOLDER_SQL_ZIP_FILE"
}

configured_sql_watch_folders() {
  configured_paths_from_file "$FOLDER_SQL_WATCH_FILE"
}

# Retorna a pasta monitorada que contém o path informado. O arquivo precisa ser
# SQL; snapshots ZIP gerados pelo próprio manager nunca voltam a disparar este fluxo.
configured_sql_watch_folder_for_path() {
  local event_path="$1"
  local folder

  [[ "${event_path,,}" == *.sql ]] || return 1

  while IFS= read -r folder || [ -n "$folder" ]; do
    [ -n "$folder" ] || continue
    if [ "$event_path" = "$folder" ] || [[ "$event_path" == "$folder/"* ]]; then
      printf '%s\n' "$folder"
      return 0
    fi
  done < <(configured_sql_watch_folders)

  return 1
}

sql_file_has_content() {
  local sql_file="$1"

  [ -f "$sql_file" ] || return 1
  LC_ALL=C grep -q '[^[:space:]]' -- "$sql_file" 2>/dev/null
}

sql_file_snapshot_signature() {
  local sql_file="$1"

  sha256sum -- "$sql_file" 2>/dev/null | awk '{print $1}'
}

sql_snapshot_saved_signature() {
  local sql_file="$1"
  [ -f "$SQL_SNAPSHOT_SIGNATURES_FILE" ] || return 0
  awk -F '\t' -v wanted="$sql_file" '$1 == wanted { value=$2 } END { if (value != "") print value }' "$SQL_SNAPSHOT_SIGNATURES_FILE"
}

save_sql_snapshot_signature() {
  local sql_file="$1"
  local signature="$2"
  local temp_file

  mkdir -p "$STATE_DIR" || return 1
  temp_file="$(mktemp "$STATE_DIR/sql-snapshot-signatures-XXXXXX")" || return 1

  if [ -f "$SQL_SNAPSHOT_SIGNATURES_FILE" ]; then
    awk -F '\t' -v wanted="$sql_file" '$1 != wanted' "$SQL_SNAPSHOT_SIGNATURES_FILE" > "$temp_file"
  fi
  printf '%s\t%s\n' "$sql_file" "$signature" >> "$temp_file"
  mv -f -- "$temp_file" "$SQL_SNAPSHOT_SIGNATURES_FILE"
}

forget_sql_snapshot_signature() {
  local sql_file="$1"
  local temp_file

  [ -f "$SQL_SNAPSHOT_SIGNATURES_FILE" ] || return 0
  mkdir -p "$STATE_DIR" || return 1
  temp_file="$(mktemp "$STATE_DIR/sql-snapshot-signatures-XXXXXX")" || return 1
  awk -F '\t' -v wanted="$sql_file" '$1 != wanted' "$SQL_SNAPSHOT_SIGNATURES_FILE" > "$temp_file"
  mv -f -- "$temp_file" "$SQL_SNAPSHOT_SIGNATURES_FILE"
}

prune_missing_sql_snapshot_signatures() {
  local folder="$1"
  local temp_file key signature

  [ -f "$SQL_SNAPSHOT_SIGNATURES_FILE" ] || return 0
  mkdir -p "$STATE_DIR" || return 1
  temp_file="$(mktemp "$STATE_DIR/sql-snapshot-signatures-XXXXXX")" || return 1

  while IFS=$'\t' read -r key signature || [ -n "$key" ]; do
    [ -n "$key" ] || continue

    if [ "$key" = "$folder" ]; then
      # Remove a assinatura legada da pasta inteira. A regra atual é por arquivo.
      continue
    fi

    if [[ "$key" == "$folder/"* ]] && [[ "${key,,}" == *.sql ]]; then
      # Arquivo apagado/renomeado deixa de ter baseline. Se reaparecer, é novo e
      # não gera ZIP na primeira gravação.
      [ -f "$key" ] || continue
    fi

    printf '%s\t%s\n' "$key" "$signature" >> "$temp_file"
  done < "$SQL_SNAPSHOT_SIGNATURES_FILE"

  mv -f -- "$temp_file" "$SQL_SNAPSHOT_SIGNATURES_FILE"
}

sql_snapshot_archive_prefix() {
  local folder="$1"
  local project_dir

  # Convenção esperada: <projeto>/exports/ddl. Se a pasta tiver outra forma,
  # usa o nome da própria pasta sem quebrar o recurso.
  project_dir="$(dirname -- "$(dirname -- "$folder")")"
  if [ -n "$project_dir" ] && [ "$project_dir" != "." ] && [ "$project_dir" != "/" ]; then
    printf '%s-ddl\n' "$(basename -- "$project_dir")"
  else
    printf '%s-ddl\n' "$(basename -- "$folder")"
  fi
}

sql_snapshot_file_token() {
  local folder="$1"
  local sql_file="$2"
  local rel token

  rel="${sql_file#"$folder"/}"
  rel="${rel%.*}"
  token="$(printf '%s' "$rel" | sed -E 's#[/\\]+#-#g; s/[^[:alnum:]_.-]+/-/g; s/^-+//; s/-+$//')"
  [ -n "$token" ] || token="sql"
  printf '%s\n' "$token"
}

sql_snapshot_zip_is_single_sql() {
  local zip_file="$1"
  local entry count entry_line

  [ -s "$zip_file" ] || return 1
  unzip -tq "$zip_file" >/dev/null 2>&1 || return 1

  count=0
  entry=""
  while IFS= read -r entry_line || [ -n "$entry_line" ]; do
    [[ "$entry_line" == */ ]] && continue
    count=$((count + 1))
    entry="$entry_line"
    [ "$count" -le 1 ] || return 1
  done < <(unzip -Z1 "$zip_file" 2>/dev/null)

  [ "$count" -eq 1 ] || return 1
  [[ "${entry,,}" == *.sql ]]
}

next_sql_snapshot_path() {
  local folder="$1"
  local sql_file="$2"
  local prefix token stamp candidate suffix=0

  prefix="$(sql_snapshot_archive_prefix "$folder")"
  token="$(sql_snapshot_file_token "$folder" "$sql_file")"
  stamp="$(date '+%Y%m%d-%H%M%S')"
  candidate="$folder/${prefix}-${token}-${stamp}.zip"

  while [ -e "$candidate" ] || [ -e "$CODE_ROOT/$(basename -- "$candidate")" ]; do
    suffix=$((suffix + 1))
    candidate="$folder/${prefix}-${token}-${stamp}-$(printf '%02d' "$suffix").zip"
  done

  printf '%s\n' "$candidate"
}

latest_valid_sql_snapshot_path() {
  local folder="$1"
  local prefix candidate
  prefix="$(sql_snapshot_archive_prefix "$folder")"

  while IFS= read -r candidate || [ -n "$candidate" ]; do
    [ -n "$candidate" ] || continue
    if sql_snapshot_zip_is_single_sql "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(
    find "$folder" -maxdepth 1 -type f -name "${prefix}-*.zip" -printf '%T@\t%p\n' 2>/dev/null |
      sort -nr | cut -f2-
  )

  return 1
}

mirror_sql_snapshot_as_latest() {
  local folder="$1"
  local local_zip="$2"
  local prefix mirror_zip temp_mirror root_count

  ensure_archive_output_dir || return 1
  prefix="$(sql_snapshot_archive_prefix "$folder")"
  mirror_zip="$CODE_ROOT/$(basename -- "$local_zip")"

  # Se já existe exatamente a cópia correta no Code, não toca no arquivo.
  root_count="$(find "$CODE_ROOT" -maxdepth 1 -type f -name "${prefix}-*.zip" | wc -l | tr -d ' ')"
  if [ "$root_count" -eq 1 ] && [ -s "$mirror_zip" ] && cmp -s -- "$local_zip" "$mirror_zip" && sql_snapshot_zip_is_single_sql "$mirror_zip"; then
    return 0
  fi

  temp_mirror="$(mktemp "$CODE_ROOT/.auto-code-ddl-latest-XXXXXX.zip")" || return 1
  if ! cp -p -- "$local_zip" "$temp_mirror" || ! sql_snapshot_zip_is_single_sql "$temp_mirror"; then
    rm -f -- "$temp_mirror"
    return 1
  fi

  # Regra do Code: somente UM snapshot DDL deste projeto, sempre o mais recente.
  find "$CODE_ROOT" -maxdepth 1 -type f -name "${prefix}-*.zip" -delete 2>/dev/null || true
  if ! mv -f -- "$temp_mirror" "$mirror_zip"; then
    rm -f -- "$temp_mirror"
    return 1
  fi

  cmp -s -- "$local_zip" "$mirror_zip" || return 1
  sql_snapshot_zip_is_single_sql "$mirror_zip" || return 1
  return 0
}

sync_latest_sql_snapshot_to_code_root() {
  local folder="$1"
  local prefix latest
  prefix="$(sql_snapshot_archive_prefix "$folder")"

  latest="$(latest_valid_sql_snapshot_path "$folder" 2>/dev/null || true)"
  if [ -z "$latest" ]; then
    # Não deixa snapshot antigo/múltiplo na raiz Code contrariar a regra nova.
    find "$CODE_ROOT" -maxdepth 1 -type f -name "${prefix}-*.zip" -delete 2>/dev/null || true
    return 0
  fi

  mirror_sql_snapshot_as_latest "$folder" "$latest"
}

snapshot_sql_file() {
  local folder="$1"
  local sql_file="$2"
  local signature saved_signature final_zip mirror_zip temp_zip

  [ -f "$sql_file" ] || {
    forget_sql_snapshot_signature "$sql_file" || true
    return 0
  }

  # Arquivo vazio (inclusive só whitespace) nunca gera ZIP e, se ainda não tem
  # baseline, continua sem baseline. Assim arquivo novo criado vazio e preenchido
  # logo depois continua sendo tratado como NOVO na primeira gravação útil.
  if ! sql_file_has_content "$sql_file"; then
    return 0
  fi

  signature="$(sql_file_snapshot_signature "$sql_file")" || return 1
  saved_signature="$(sql_snapshot_saved_signature "$sql_file")"

  # Primeira vez que um SQL preenchido aparece = baseline. Arquivo novo não gera ZIP.
  if [ -z "$saved_signature" ]; then
    save_sql_snapshot_signature "$sql_file" "$signature" || return 1
    LOG_CONTEXT=backup log "DDL novo registrado sem ZIP: $sql_file"
    return 0
  fi

  [ "$saved_signature" != "$signature" ] || return 0

  ensure_archive_output_dir || return 1
  final_zip="$(next_sql_snapshot_path "$folder" "$sql_file")"
  mirror_zip="$CODE_ROOT/$(basename -- "$final_zip")"
  temp_zip="$(mktemp '/tmp/auto-code-sql-snapshot-XXXXXX.zip')" || return 1

  taskbar_status zip "$(basename -- "$sql_file")"

  local rel_sql
  rel_sql="${sql_file#"$folder"/}"
  rm -f -- "$temp_zip"
  if ! (
    cd "$folder" || exit 1
    zip -q "$temp_zip" -- "$rel_sql"
  ); then
    log "ERRO: falha ao gerar snapshot SQL de $sql_file; fonte mantido."
    rm -f -- "$temp_zip"
    return 1
  fi

  if ! sql_snapshot_zip_is_single_sql "$temp_zip"; then
    log "ERRO: snapshot SQL não contém exatamente um SQL válido: $sql_file"
    rm -f -- "$temp_zip"
    return 1
  fi

  if ! cp -f -- "$temp_zip" "$final_zip"; then
    log "ERRO: snapshot SQL não pôde ser gravado em $final_zip; fonte mantido."
    rm -f -- "$temp_zip" "$final_zip"
    return 1
  fi
  rm -f -- "$temp_zip"

  if ! mirror_sql_snapshot_as_latest "$folder" "$final_zip"; then
    log "ERRO: snapshot criado localmente, mas não pôde virar o único ZIP DDL em $CODE_ROOT."
    rm -f -- "$final_zip"
    return 1
  fi

  if ! save_sql_snapshot_signature "$sql_file" "$signature"; then
    log "ERRO: snapshot criado, mas não foi possível salvar a assinatura de idempotência: $sql_file"
    rm -f -- "$final_zip" "$mirror_zip"
    return 1
  fi

  log "OK SQL SNAPSHOT: $final_zip -> $mirror_zip (1 SQL: $(basename -- "$sql_file")); SQL preservado."
  return 0
}

snapshot_sql_folder() {
  local folder="$1"
  local sql_file failed=0

  if [ ! -d "$folder" ]; then
    log "Pasta SQL monitorada ainda não existe: $folder"
    return 0
  fi

  prune_missing_sql_snapshot_signatures "$folder" || return 1

  while IFS= read -r -d '' sql_file; do
    snapshot_sql_file "$folder" "$sql_file" || failed=1
  done < <(
    find "$folder" -type f -iname '*.sql' ! -name '*:Zone.Identifier' -print0 2>/dev/null | sort -z
  )

  # Mesmo sem alteração, normaliza a raiz Code para conter somente o snapshot
  # DDL válido mais recente deste projeto.
  sync_latest_sql_snapshot_to_code_root "$folder" || failed=1
  return "$failed"
}

mark_sql_snapshot_dirty() {
  local folder="$1"
  [ -n "$folder" ] || return 0

  if [ -z "${DIRTY_SQL_SNAPSHOT_FOLDERS[$folder]+x}" ]; then
    LOG_CONTEXT=backup log "Alteração DDL detectada; snapshot SQL pendente: $folder"
  fi
  DIRTY_SQL_SNAPSHOT_FOLDERS["$folder"]=1
  LAST_SOURCE_CHANGE="$(date +%s)"
}

sql_snapshot_dirty_count() {
  printf '%s\n' "${#DIRTY_SQL_SNAPSHOT_FOLDERS[@]}"
}

snapshot_dirty_sql_folders() {
  local folder failed=0
  local -a pending=()

  [ "${#DIRTY_SQL_SNAPSHOT_FOLDERS[@]}" -gt 0 ] || return 0
  for folder in "${!DIRTY_SQL_SNAPSHOT_FOLDERS[@]}"; do
    pending+=("$folder")
  done

  for folder in "${pending[@]}"; do
    wait_if_paused
    if snapshot_sql_folder "$folder"; then
      unset 'DIRTY_SQL_SNAPSHOT_FOLDERS[$folder]'
    else
      failed=1
    fi
  done

  return "$failed"
}

reconcile_configured_sql_snapshots() {
  local folder failed=0

  while IFS= read -r folder || [ -n "$folder" ]; do
    [ -n "$folder" ] || continue
    snapshot_sql_folder "$folder" || failed=1
  done < <(configured_sql_watch_folders)

  return "$failed"
}

pending_change_work() {
  [ "${#DIRTY_BACKUP_TARGETS[@]}" -gt 0 ] || [ "${#DIRTY_SQL_SNAPSHOT_FOLDERS[@]}" -gt 0 ]
}

process_dirty_work() {
  local failed=0

  if [ "${#DIRTY_SQL_SNAPSHOT_FOLDERS[@]}" -gt 0 ]; then
    snapshot_dirty_sql_folders || failed=1
  fi

  if [ "${#DIRTY_BACKUP_TARGETS[@]}" -gt 0 ]; then
    backup_dirty_targets || failed=1
  fi

  if [ "$failed" -eq 0 ] && [ "${#DIRTY_SQL_SNAPSHOT_FOLDERS[@]}" -eq 0 ] && [ "${#DIRTY_BACKUP_TARGETS[@]}" -eq 0 ]; then
    LAST_SOURCE_CHANGE=0
  fi

  return "$failed"
}

# Legado explícito: chamado apenas por --sql-zip-once. Mantém a semântica antiga
# de consolidar SQLs soltos no ZIP do minuto e apagar somente após validação.
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
