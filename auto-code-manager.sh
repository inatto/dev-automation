#!/usr/bin/env bash
# cd /home/daniel/Code/sind-infra/deploy
# Mantém o loop vivo: erros de importação/backup são logados e o próximo ciclo continua.
set -uo pipefail

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

run_or_log() {
  local desc="$1"
  shift

  if ! "$@"; then
    local rc=$?
    log "ERRO em $desc (rc=$rc): $*"
    return "$rc"
  fi

  return 0
}

downloads_dir() {
  if command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
    local win_profile
    win_profile="$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r' || true)"

    if [ -n "$win_profile" ]; then
      local wsl_profile
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
  local s1 s2

  [ -f "$file" ] || return 1

  s1="$(stat -c %s "$file" 2>/dev/null || echo 0)"
  sleep "$STABLE_WAIT"
  [ -f "$file" ] || return 1
  s2="$(stat -c %s "$file" 2>/dev/null || echo 0)"

  [ "$s1" = "$s2" ] && [ "$s1" -gt 0 ]
}

ensure_files() {
  if [ ! -f "$IGNORE_FILE" ]; then
    cat > "$IGNORE_FILE" <<'EOT'
.git/
.idea/
*.log
*.zip
*:Zone.Identifier

node_modules/
.venv/
venv/
env/
dist/
build/
.astro/
.cache/
.output/
.output*/
public/
temp/
tmp/
EOT
    log "Criado: $IGNORE_FILE"
  fi

  if [ ! -f "$PROJECTS_FILE" ]; then
    cat > "$PROJECTS_FILE" <<'EOT'
site-inst
EOT
    log "Criado: $PROJECTS_FILE"
  fi
}

clean_file_to_stdout() {
  local file="$1"

  [ -f "$file" ] || return 0

  sed -E \
    -e 's/\r$//' \
    -e 's/^[[:space:]]+//' \
    -e 's/[[:space:]]+$//' \
    -e '/^[[:space:]]*$/d' \
    -e '/^[[:space:]]*#/d' \
    "$file"
}

project_for_zip() {
  local zip_name="$1"
  local dir project best=""

  for dir in "$CODE_ROOT"/*; do
    [ -d "$dir" ] || continue

    project="$(basename "$dir")"

    case "$project" in
      .cache|.idea) continue ;;
    esac

    if [[ "$zip_name" == "$project.zip" || "$zip_name" == "$project"-*.zip || "$zip_name" == "$project"_*.zip ]]; then
      [ ${#project} -gt ${#best} ] && best="$project"
    fi
  done

  echo "$best"
}

import_one_zip() {
  local zip_file="$1"
  local zip_name project project_dir target

  zip_name="$(basename "$zip_file")"
  project="$(project_for_zip "$zip_name")"

  if [ -z "$project" ]; then
    log "Ignorando ZIP sem pasta/projeto correspondente: $zip_name"
    return 0
  fi

  if ! stable_file "$zip_file"; then
    log "Ainda baixando/gravando: $zip_name"
    return 0
  fi

  project_dir="$CODE_ROOT/$project"
  target="$project_dir/$zip_name"

  log "Importando $zip_name -> $project_dir"

  if ! mv -f -- "$zip_file" "$target"; then
    log "ERRO importando: falhou mv de $zip_name"
    return 1
  fi

  if ! unzip -oq -- "$target" -d "$project_dir"; then
    log "ERRO importando: falhou unzip de $target"
    return 1
  fi

  rm -f -- "$target" || true
  log "OK importado: $zip_name"
  return 0
}

import_downloads() {
  local dl
  dl="$(downloads_dir)"

  if [ -z "$dl" ] || [ ! -d "$dl" ]; then
    log "Downloads não encontrado."
    return 0
  fi

  log "Verificando Downloads: $dl"

  find "$dl" -maxdepth 1 -type f -iname "*.zip" -print0 2>/dev/null |
  while IFS= read -r -d '' zip_file; do
    import_one_zip "$zip_file" || log "Continuando apesar de erro ao importar: $(basename "$zip_file")"
  done

  return 0
}

clean_zone() {
  log "Limpando Zone.Identifier em $CODE_ROOT"
  find "$CODE_ROOT" -type f -name "*:Zone.Identifier" -print -delete 2>/dev/null || true
}

make_clean_ignore() {
  local clean_ignore="$1"

  clean_file_to_stdout "$IGNORE_FILE" > "$clean_ignore" || true

  {
    echo "*.zip"
    echo "*.log"
    echo "*:Zone.Identifier"
  } >> "$clean_ignore"

  sort -u "$clean_ignore" -o "$clean_ignore"
}

zip_one_ddl_file() {
  local src="$1"
  local zip_file="${src%.*}.zip"

  case "$src" in
    *.zip|*:Zone.Identifier) return 0 ;;
  esac

  [ -f "$src" ] || return 0

  if [ -f "$zip_file" ] && [ "$zip_file" -nt "$src" ]; then
    log "DDL ZIP atualizado, pulando: $(basename "$zip_file")"
    return 0
  fi

  log "Compactando DDL: $(basename "$src") -> $(basename "$zip_file")"

  (
    cd "$(dirname "$src")" || exit 1
    zip -q -j "$(basename "$zip_file")" "$(basename "$src")"
  )
}

zip_ddl_exports() {
  if [ ! -d "$DDL_EXPORT_DIR" ]; then
    log "DDL_EXPORT_DIR não existe, pulando: $DDL_EXPORT_DIR"
    return 0
  fi

  log "Compactando arquivos DDL antes do backup do sind-infra: $DDL_EXPORT_DIR"

  find "$DDL_EXPORT_DIR" -maxdepth 1 -type f ! -iname "*.zip" ! -name "*:Zone.Identifier" -print0 2>/dev/null |
  while IFS= read -r -d '' ddl_file; do
    zip_one_ddl_file "$ddl_file" || log "ERRO compactando DDL, continuando: $(basename "$ddl_file")"
  done

  return 0
}

backup_project() {
  local project="$1"
  local project_dir tmp_dir final tmp_zip clean_ignore rc=0

  project_dir="$CODE_ROOT/$project"

  if [ ! -d "$project_dir" ]; then
    log "Projeto autorizado não existe, ignorando backup: $project_dir"
    return 0
  fi

  if [ "$project" = "sind-infra" ]; then
    zip_ddl_exports || log "Continuando backup do sind-infra apesar de erro na compactação dos DDLs."
  fi

  tmp_dir="/tmp/auto-code-manager-$project-$$"
  final="$CODE_ROOT/$project.zip"
  tmp_zip="$CODE_ROOT/.$project.zip.tmp"
  clean_ignore="/tmp/auto-code-manager-ignore-$project-$$.txt"

  rm -rf -- "$tmp_dir" || true
  rm -f -- "$tmp_zip" "$clean_ignore" || true

  if ! mkdir -p "$tmp_dir"; then
    log "ERRO backup: não conseguiu criar tmp_dir: $tmp_dir"
    return 1
  fi

  make_clean_ignore "$clean_ignore"

  log "Backup autorizado: $project -> $final"

  if [ "$project" = "sind-infra" ]; then
    rsync -a \
      --include='sind-oracle/exports/ddl/*.zip' \
      --exclude-from="$clean_ignore" \
      "$project_dir/" "$tmp_dir/" || rc=$?
  else
    rsync -a \
      --exclude-from="$clean_ignore" \
      "$project_dir/" "$tmp_dir/" || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    log "ERRO backup: rsync falhou para $project (rc=$rc)"
    rm -rf -- "$tmp_dir" "$clean_ignore" || true
    return "$rc"
  fi

  (
    cd "$tmp_dir" || exit 1
    zip -qr "$tmp_zip" .
  ) || rc=$?

  if [ "$rc" -ne 0 ]; then
    log "ERRO backup: zip falhou para $project (rc=$rc)"
    rm -rf -- "$tmp_dir" "$clean_ignore" || true
    rm -f -- "$tmp_zip" || true
    return "$rc"
  fi

  if ! mv -f -- "$tmp_zip" "$final"; then
    log "ERRO backup: mv falhou para $final"
    rm -rf -- "$tmp_dir" "$clean_ignore" || true
    rm -f -- "$tmp_zip" || true
    return 1
  fi

  rm -rf -- "$tmp_dir" "$clean_ignore" || true

  log "OK backup: $final"
  return 0
}

backup_all() {
  local project

  log "Gerando backups somente dos projetos autorizados em:"
  log "  $PROJECTS_FILE"

  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    log "Projeto autorizado para backup: $project"
    backup_project "$project" || log "ERRO no backup de $project; loop vai continuar."
  done < <(clean_file_to_stdout "$PROJECTS_FILE")

  return 0
}

stop() {
  echo
  line
  echo "Encerrado."
  exit 0
}

trap stop INT TERM

if [ ! -d "$CODE_ROOT" ]; then
  echo "ERRO: CODE_ROOT não existe: $CODE_ROOT" >&2
  exit 1
fi

ensure_files

line
echo "Auto Code Manager"
line
echo "CODE_ROOT:      $CODE_ROOT"
echo "IGNORE_FILE:    $IGNORE_FILE"
echo "PROJECTS_FILE:  $PROJECTS_FILE"
echo "DDL_EXPORT_DIR: $DDL_EXPORT_DIR"
echo "Downloads:      $(downloads_dir)"
echo "Backups:        somente projetos listados em auto-code-manager.projects"
echo "Importação:     todos os ZIPs que batem com pasta em /home/daniel/Code"
echo "Intervalo:      ${INTERVAL}s"
echo "Backup cada:    ${BACKUP_EVERY}s"
echo "Zone cada:      ${ZONE_EVERY}s"
echo "Para parar:     Ctrl+C"
line

cycle=1
last_backup=0
last_zone=0

while true; do
  now="$(date +%s)"

  line
  log "Ciclo #$cycle"

  import_downloads || log "ERRO em import_downloads; loop vai continuar."

  if [ $((now - last_zone)) -ge "$ZONE_EVERY" ]; then
    clean_zone || log "ERRO em clean_zone; loop vai continuar."
    last_zone="$now"
  fi

  if [ $((now - last_backup)) -ge "$BACKUP_EVERY" ]; then
    backup_all || log "ERRO em backup_all; loop vai continuar."
    last_backup="$now"
  else
    log "Backup ainda não venceu."
  fi

  cycle=$((cycle + 1))
  sleep "$INTERVAL"
done
