#!/usr/bin/env bash
set -uo pipefail
#cd /home/daniel/Code/sind-infra/deploy/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CODE_ROOT="/home/daniel/Code"
IGNORE_FILE="$SCRIPT_DIR/auto-code-manager.ignore"
PROJECTS_FILE="$SCRIPT_DIR/auto-code-manager.projects"
DDL_EXPORT_DIR="$CODE_ROOT/sind-infra/sind-oracle/exports/ddl"

INTERVAL=2
ZONE_EVERY=4
BACKUP_EVERY=10
STABLE_WAIT=2

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

line() {
  echo "────────────────────────────────────────────────────────────"
}

downloads_dir() {
  local win_profile=""
  local wsl_profile=""

  if command -v cmd.exe >/dev/null 2>&1 &&
     command -v wslpath >/dev/null 2>&1; then

    win_profile="$(
      cmd.exe /c "echo %USERPROFILE%" 2>/dev/null |
      tr -d '\r'
    )"

    if [ -n "$win_profile" ]; then
      wsl_profile="$(wslpath "$win_profile" 2>/dev/null || true)"

      if [ -d "$wsl_profile/Downloads" ]; then
        echo "$wsl_profile/Downloads"
        return
      fi
    fi
  fi

  if [ -d "/mnt/c/Users/${USER}/Downloads" ]; then
    echo "/mnt/c/Users/${USER}/Downloads"
    return
  fi

  echo ""
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
  [ -f "$IGNORE_FILE" ] || touch "$IGNORE_FILE"

  if [ ! -f "$PROJECTS_FILE" ]; then
    echo "site-inst" > "$PROJECTS_FILE"
  fi
}

project_for_zip() {
  local zip_name="$1"
  local dir
  local project
  local best=""

  for dir in "$CODE_ROOT"/*; do
    [ -d "$dir" ] || continue

    project="$(basename "$dir")"

    if [[ "$zip_name" == "$project.zip" ||
          "$zip_name" == "$project"-*.zip ||
          "$zip_name" == "$project"_*.zip ]]; then

      if [ "${#project}" -gt "${#best}" ]; then
        best="$project"
      fi
    fi
  done

  echo "$best"
}

import_one_zip() {
  local zip_file="$1"
  local zip_name project project_dir temp_dir source_dir
  local total_files checked_files rel destination

  zip_name="$(basename "$zip_file")"
  project="$(project_for_zip "$zip_name")"

  if [ -z "$project" ]; then
    log "Ignorando ZIP sem projeto: $zip_name"
    return 0
  fi

  if ! stable_file "$zip_file"; then
    log "ZIP ainda está sendo gravado: $zip_name"
    return 0
  fi

  project_dir="$CODE_ROOT/$project"
  temp_dir="$(mktemp -d "/tmp/auto-code-import-${project}-XXXXXX")"

  line
  log "IMPORTAÇÃO INICIADA"
  log "ZIP:        $zip_file"
  log "Projeto:    $project"
  log "Destino:    $project_dir"
  log "Temporário: $temp_dir"

  if ! unzip -tq "$zip_file" >/dev/null 2>&1; then
    log "ERRO: ZIP inválido ou corrompido. O ZIP foi mantido."
    rm -rf -- "$temp_dir"
    return 1
  fi

  log "Extraindo ZIP para a pasta temporária..."
  if ! unzip -oq -- "$zip_file" -d "$temp_dir"; then
    log "ERRO: falha ao extrair. O ZIP foi mantido."
    rm -rf -- "$temp_dir"
    return 1
  fi

  if [ -d "$temp_dir/$project" ]; then
    source_dir="$temp_dir/$project"
    log "Raiz do ZIP identificada: $project/"
  else
    source_dir="$temp_dir"
    log "ZIP sem pasta raiz do projeto; usando a raiz do ZIP."
  fi

  total_files="$(find "$source_dir" -type f -printf '.' 2>/dev/null | wc -c)"

  if [ "$total_files" -eq 0 ]; then
    log "ERRO: nenhum arquivo foi extraído. O ZIP foi mantido."
    rm -rf -- "$temp_dir"
    return 1
  fi

  log "Arquivos extraídos: $total_files"
  find "$source_dir" -type f -printf '  EXTRAÍDO: %P\n'

  log "Copiando para o destino..."
  if ! rsync -a --itemize-changes -- "$source_dir/" "$project_dir/" | sed 's/^/  RSYNC: /'; then
    log "ERRO: falha ao copiar. O ZIP foi mantido."
    rm -rf -- "$temp_dir"
    return 1
  fi

  log "Conferindo arquivo por arquivo no destino..."
  checked_files=0

  while IFS= read -r -d '' rel; do
    destination="$project_dir/$rel"

    if [ ! -f "$destination" ]; then
      log "ERRO: arquivo não apareceu no destino: $destination"
      log "ZIP mantido: $zip_file"
      rm -rf -- "$temp_dir"
      return 1
    fi

    if ! cmp -s -- "$source_dir/$rel" "$destination"; then
      log "ERRO: arquivo no destino está diferente: $destination"
      log "ZIP mantido: $zip_file"
      rm -rf -- "$temp_dir"
      return 1
    fi

    checked_files=$((checked_files + 1))
    log "CONFIRMADO [$checked_files/$total_files]: $destination"
  done < <(find "$source_dir" -type f -printf '%P\0')

  if [ "$checked_files" -ne "$total_files" ]; then
    log "ERRO: conferidos $checked_files de $total_files arquivos. ZIP mantido."
    rm -rf -- "$temp_dir"
    return 1
  fi

  rm -rf -- "$temp_dir"

  log "Todos os $checked_files arquivos foram conferidos no destino."
  log "Apagando ZIP original de Downloads..."

  if ! rm -f -- "$zip_file" || [ -e "$zip_file" ]; then
    log "ERRO: arquivos importados, mas o ZIP não foi apagado: $zip_file"
    return 1
  fi

  log "IMPORTAÇÃO CONCLUÍDA"
  log "Destino confirmado: $project_dir"
  log "ZIP apagado: $zip_file"
  line
}

import_downloads() {
  local downloads

  downloads="$(downloads_dir)"

  if [ -z "$downloads" ] || [ ! -d "$downloads" ]; then
    log "Downloads não encontrado."
    return
  fi

  log "Verificando Downloads: $downloads"

  while IFS= read -r -d '' zip_file; do
    import_one_zip "$zip_file" ||
      log "Falha ao importar: $(basename "$zip_file")"
  done < <(
    find "$downloads" \
      -maxdepth 1 \
      -type f \
      -iname "*.zip" \
      -print0 2>/dev/null
  )
}

clean_zone() {
  log "Limpando Zone.Identifier em $CODE_ROOT"

  find "$CODE_ROOT" \
    -type f \
    -name "*:Zone.Identifier" \
    -delete 2>/dev/null ||
    true
}

make_rsync_filter() {
  local output="$1"
  local pattern
  local action
  local directory

  : > "$output"

  while IFS= read -r pattern || [ -n "$pattern" ]; do
    [ -n "$pattern" ] || continue

    action="-"

    if [[ "$pattern" == !* ]]; then
      action="+"
      pattern="${pattern:1}"
    fi

    if [[ "$pattern" == */ ]]; then
      directory="${pattern%/}"

      if [[ "$directory" == */* ]]; then
        echo "$action /$directory/***" >> "$output"
      else
        echo "$action $directory/***" >> "$output"
        echo "$action **/$directory/***" >> "$output"
      fi
    elif [[ "$pattern" == */* ]]; then
      echo "$action /$pattern" >> "$output"
    else
      echo "$action $pattern" >> "$output"
      echo "$action **/$pattern" >> "$output"
    fi
  done < <(clean_file "$IGNORE_FILE")

  echo "- *:Zone.Identifier" >> "$output"
  echo "- **/*:Zone.Identifier" >> "$output"
}

zip_ddl_exports() {
  local file
  local zip_file

  [ -d "$DDL_EXPORT_DIR" ] || return 0

  log "Compactando DDLs em $DDL_EXPORT_DIR"

  while IFS= read -r -d '' file; do
    zip_file="${file%.*}.zip"

    if [ -f "$zip_file" ] && [ "$zip_file" -nt "$file" ]; then
      continue
    fi

    (
      cd "$(dirname "$file")" || exit 1
      zip -q -j "$(basename "$zip_file")" "$(basename "$file")"
    ) || log "ERRO compactando DDL: $(basename "$file")"

  done < <(
    find "$DDL_EXPORT_DIR" \
      -maxdepth 1 \
      -type f \
      ! -iname "*.zip" \
      ! -name "*:Zone.Identifier" \
      -print0 2>/dev/null
  )
}

backup_project() {
  local project="$1"
  local project_dir="$CODE_ROOT/$project"
  local temp_dir
  local temp_zip
  local final_zip
  local filter_file

  if [ ! -d "$project_dir" ]; then
    log "Projeto não existe: $project_dir"
    return 0
  fi

  if [ "$project" = "sind-infra" ]; then
    zip_ddl_exports
  fi

  temp_dir="$(mktemp -d "/tmp/auto-code-backup-${project}-XXXXXX")"
  filter_file="$(mktemp "/tmp/auto-code-filter-${project}-XXXXXX")"
  temp_zip="/tmp/${project}-backup-$$.zip"
  final_zip="$CODE_ROOT/$project.zip"

  make_rsync_filter "$filter_file"

  log "Gerando backup: $project -> $final_zip"

  if ! rsync -a \
    --filter="merge $filter_file" \
    "$project_dir/" \
    "$temp_dir/"; then

    log "ERRO no rsync do projeto: $project"
    rm -rf -- "$temp_dir" "$filter_file"
    return 1
  fi

  if ! (
    cd "$temp_dir" &&
    zip -qr "$temp_zip" .
  ); then
    log "ERRO ao compactar projeto: $project"
    rm -rf -- "$temp_dir" "$filter_file" "$temp_zip"
    return 1
  fi

  mv -f -- "$temp_zip" "$final_zip"
  rm -rf -- "$temp_dir" "$filter_file"

  log "OK backup: $final_zip"
}

backup_all() {
  local project

  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    backup_project "$project"
  done < <(clean_file "$PROJECTS_FILE")
}

stop() {
  echo
  line
  echo "Encerrado."
  exit 0
}

trap stop INT TERM

if [ ! -d "$CODE_ROOT" ]; then
  echo "ERRO: diretório não existe: $CODE_ROOT" >&2
  exit 1
fi

ensure_files

line
echo "Auto Code Manager"
line
echo "CODE_ROOT:     $CODE_ROOT"
echo "Downloads:     $(downloads_dir)"
echo "Intervalo:     ${INTERVAL}s"
echo "Backup cada:   ${BACKUP_EVERY}s"
echo "Zone cada:     ${ZONE_EVERY}s"
line

cycle=1
last_backup=0
last_zone=0

while true; do
  now="$(date +%s)"

  line
  log "Ciclo #$cycle"

  import_downloads

  if [ $((now - last_zone)) -ge "$ZONE_EVERY" ]; then
    clean_zone
    last_zone="$now"
  fi

  if [ $((now - last_backup)) -ge "$BACKUP_EVERY" ]; then
    backup_all
    last_backup="$now"
  else
    log "Backup ainda não venceu."
  fi

  cycle=$((cycle + 1))
  sleep "$INTERVAL"
done