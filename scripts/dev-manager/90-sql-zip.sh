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

sql_folder_snapshot_signature() {
  local folder="$1"

  [ -d "$folder" ] || {
    printf 'missing\n'
    return 0
  }

  python3 - "$folder" <<'PY_SQL_SIGNATURE'
import hashlib
import os
import sys

root = os.path.abspath(sys.argv[1])
h = hashlib.sha256()
count = 0
for current, dirs, files in os.walk(root):
    dirs.sort()
    files.sort()
    for name in files:
        if not name.lower().endswith('.sql') or name.endswith(':Zone.Identifier'):
            continue
        full = os.path.join(current, name)
        rel = os.path.relpath(full, root).replace(os.sep, '/')
        try:
            with open(full, 'rb') as fh:
                digest = hashlib.sha256(fh.read()).hexdigest()
        except OSError:
            continue
        h.update(rel.encode('utf-8', errors='surrogateescape'))
        h.update(b'\0')
        h.update(digest.encode('ascii'))
        h.update(b'\n')
        count += 1
print(f'{count}:{h.hexdigest()}')
PY_SQL_SIGNATURE
}

sql_snapshot_saved_signature() {
  local folder="$1"
  [ -f "$SQL_SNAPSHOT_SIGNATURES_FILE" ] || return 0
  awk -F '\t' -v wanted="$folder" '$1 == wanted { value=$2 } END { if (value != "") print value }' "$SQL_SNAPSHOT_SIGNATURES_FILE"
}

save_sql_snapshot_signature() {
  local folder="$1"
  local signature="$2"
  local temp_file

  mkdir -p "$STATE_DIR" || return 1
  temp_file="$(mktemp "$STATE_DIR/sql-snapshot-signatures-XXXXXX")" || return 1

  if [ -f "$SQL_SNAPSHOT_SIGNATURES_FILE" ]; then
    awk -F '\t' -v wanted="$folder" '$1 != wanted' "$SQL_SNAPSHOT_SIGNATURES_FILE" > "$temp_file"
  fi
  printf '%s\t%s\n' "$folder" "$signature" >> "$temp_file"
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

latest_sql_snapshot_path() {
  local folder="$1"
  local prefix
  prefix="$(sql_snapshot_archive_prefix "$folder")"
  find "$folder" -maxdepth 1 -type f -name "${prefix}-*.zip" -printf '%f\n' 2>/dev/null | sort | tail -n1 | sed "s#^#$folder/#"
}

ensure_existing_sql_snapshot_pair() {
  local folder="$1"
  local local_zip mirror_zip

  local_zip="$(latest_sql_snapshot_path "$folder")"
  [ -n "$local_zip" ] && [ -s "$local_zip" ] || return 1
  unzip -tq "$local_zip" >/dev/null 2>&1 || return 1

  mirror_zip="$CODE_ROOT/$(basename -- "$local_zip")"
  if [ ! -s "$mirror_zip" ] || ! cmp -s -- "$local_zip" "$mirror_zip" || ! unzip -tq "$mirror_zip" >/dev/null 2>&1; then
    ensure_archive_output_dir || return 1
    cp -f -- "$local_zip" "$mirror_zip" || return 1
    cmp -s -- "$local_zip" "$mirror_zip" || return 1
    unzip -tq "$mirror_zip" >/dev/null 2>&1 || return 1
    log "OK SQL SNAPSHOT MIRROR: restaurado em $mirror_zip"
  fi

  return 0
}

next_sql_snapshot_path() {
  local folder="$1"
  local prefix stamp candidate suffix=0

  prefix="$(sql_snapshot_archive_prefix "$folder")"
  stamp="$(date '+%Y%m%d-%H%M%S')"
  candidate="$folder/${prefix}-${stamp}.zip"

  while [ -e "$candidate" ] || [ -e "$CODE_ROOT/$(basename -- "$candidate")" ]; do
    suffix=$((suffix + 1))
    candidate="$folder/${prefix}-${stamp}-$(printf '%02d' "$suffix").zip"
  done

  printf '%s\n' "$candidate"
}

snapshot_sql_folder() {
  local folder="$1"
  local signature saved_signature final_zip mirror_zip temp_zip
  local sql_count

  if [ ! -d "$folder" ]; then
    log "Pasta SQL monitorada ainda não existe: $folder"
    return 0
  fi

  signature="$(sql_folder_snapshot_signature "$folder")" || return 1
  sql_count="${signature%%:*}"
  [ "${sql_count:-0}" -gt 0 ] || {
    save_sql_snapshot_signature "$folder" "$signature" || true
    return 0
  }

  saved_signature="$(sql_snapshot_saved_signature "$folder")"
  if [ -n "$saved_signature" ] && [ "$saved_signature" = "$signature" ]; then
    if ensure_existing_sql_snapshot_pair "$folder"; then
      return 0
    fi
  fi

  ensure_archive_output_dir || return 1
  final_zip="$(next_sql_snapshot_path "$folder")"
  mirror_zip="$CODE_ROOT/$(basename -- "$final_zip")"
  temp_zip="$(mktemp '/tmp/auto-code-sql-snapshot-XXXXXX.zip')" || return 1

  taskbar_status zip "$(basename -- "$folder")"

  if ! python3 - "$folder" "$temp_zip" <<'PY_SQL_SNAPSHOT'
import os
import sys
import zipfile

root = os.path.abspath(sys.argv[1])
out = sys.argv[2]
entries = []
for current, dirs, files in os.walk(root):
    dirs.sort()
    files.sort()
    for name in files:
        if not name.lower().endswith('.sql') or name.endswith(':Zone.Identifier'):
            continue
        full = os.path.join(current, name)
        rel = os.path.relpath(full, root).replace(os.sep, '/')
        entries.append((full, rel))

with zipfile.ZipFile(out, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
    for full, rel in entries:
        zf.write(full, rel)
PY_SQL_SNAPSHOT
  then
    log "ERRO: falha ao gerar snapshot SQL em $folder; fontes mantidos."
    rm -f -- "$temp_zip"
    return 1
  fi

  if [ ! -s "$temp_zip" ] || ! unzip -tq "$temp_zip" >/dev/null 2>&1; then
    log "ERRO: validação do snapshot SQL falhou; fontes mantidos: $folder"
    rm -f -- "$temp_zip"
    return 1
  fi

  # Copia os mesmos bytes para os dois destinos; os .sql originais permanecem.
  if ! cp -f -- "$temp_zip" "$final_zip" || ! cp -f -- "$temp_zip" "$mirror_zip"; then
    log "ERRO: snapshot SQL não pôde ser gravado nos dois destinos; fontes mantidos."
    rm -f -- "$final_zip" "$mirror_zip" "$temp_zip"
    return 1
  fi

  if ! cmp -s -- "$final_zip" "$mirror_zip" || ! unzip -tq "$final_zip" >/dev/null 2>&1 || ! unzip -tq "$mirror_zip" >/dev/null 2>&1; then
    log "ERRO: cópias do snapshot SQL divergiram ou ficaram inválidas; fontes mantidos."
    rm -f -- "$final_zip" "$mirror_zip" "$temp_zip"
    return 1
  fi

  rm -f -- "$temp_zip"
  if ! save_sql_snapshot_signature "$folder" "$signature"; then
    log "ERRO: snapshot criado, mas não foi possível salvar a assinatura de idempotência: $folder"
    return 1
  fi

  log "OK SQL SNAPSHOT: $final_zip -> $mirror_zip (${sql_count} arquivo(s)); SQLs preservados."
  return 0
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
