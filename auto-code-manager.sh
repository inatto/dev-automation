#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CODE_ROOT="/home/daniel/Code"
IGNORE_FILE="$SCRIPT_DIR/auto-code-manager.ignore"
PROJECTS_FILE="$SCRIPT_DIR/auto-code-manager.projects"

INTERVAL=6
BACKUP_EVERY=30
ZONE_EVERY=30
STABLE_WAIT=2

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

line() {
  echo "────────────────────────────────────────────────────────────"
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
    cat > "$IGNORE_FILE" <<'EOF'
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
EOF
    log "Criado: $IGNORE_FILE"
  fi

  if [ ! -f "$PROJECTS_FILE" ]; then
    cat > "$PROJECTS_FILE" <<'EOF'
site-inst
EOF
    log "Criado: $PROJECTS_FILE"
  fi
}

clean_file_to_stdout() {
  local file="$1"

  [ -f "$file" ] || return

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

import_downloads() {
  local dl
  dl="$(downloads_dir)"

  if [ -z "$dl" ] || [ ! -d "$dl" ]; then
    log "Downloads não encontrado."
    return
  fi

  log "Verificando Downloads: $dl"

  find "$dl" -maxdepth 1 -type f -iname "*.zip" -print0 2>/dev/null |
  while IFS= read -r -d '' zip_file; do
    local zip_name project project_dir target

    zip_name="$(basename "$zip_file")"
    project="$(project_for_zip "$zip_name")"

    if [ -z "$project" ]; then
      log "Ignorando ZIP sem pasta/projeto correspondente: $zip_name"
      continue
    fi

    if ! stable_file "$zip_file"; then
      log "Ainda baixando/gravando: $zip_name"
      continue
    fi

    project_dir="$CODE_ROOT/$project"
    target="$project_dir/$zip_name"

    log "Importando $zip_name -> $project_dir"

    mv -f -- "$zip_file" "$target"
    unzip -oq -- "$target" -d "$project_dir"
    rm -f -- "$target"

    log "OK importado: $zip_name"
  done
}

clean_zone() {
  log "Limpando Zone.Identifier em $CODE_ROOT"
  find "$CODE_ROOT" -type f -name "*:Zone.Identifier" -print -delete 2>/dev/null || true
}

make_clean_ignore() {
  local clean_ignore="$1"

  clean_file_to_stdout "$IGNORE_FILE" > "$clean_ignore"

  {
    echo "*.zip"
    echo "*.log"
    echo "*:Zone.Identifier"
  } >> "$clean_ignore"

  sort -u "$clean_ignore" -o "$clean_ignore"
}

backup_project() {
  local project="$1"
  local project_dir tmp_dir final tmp_zip clean_ignore

  project_dir="$CODE_ROOT/$project"

  if [ ! -d "$project_dir" ]; then
    log "Projeto autorizado não existe, ignorando backup: $project_dir"
    return
  fi

  tmp_dir="/tmp/auto-code-manager-$project-$$"
  final="$CODE_ROOT/$project.zip"
  tmp_zip="$CODE_ROOT/.$project.zip.tmp"
  clean_ignore="/tmp/auto-code-manager-ignore-$$.txt"

  rm -rf -- "$tmp_dir"
  rm -f -- "$tmp_zip" "$clean_ignore"
  mkdir -p "$tmp_dir"

  make_clean_ignore "$clean_ignore"

  log "Backup autorizado: $project -> $final"

  rsync -a \
    --exclude-from="$clean_ignore" \
    "$project_dir/" "$tmp_dir/"

  (
    cd "$tmp_dir"
    zip -qr "$tmp_zip" .
  )

  mv -f -- "$tmp_zip" "$final"

  rm -rf -- "$tmp_dir" "$clean_ignore"

  log "OK backup: $final"
}

backup_all() {
  local project

  log "Gerando backups somente dos projetos autorizados em:"
  log "  $PROJECTS_FILE"

  while IFS= read -r project; do
    backup_project "$project"
  done < <(clean_file_to_stdout "$PROJECTS_FILE")
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
echo "CODE_ROOT:     $CODE_ROOT"
echo "IGNORE_FILE:   $IGNORE_FILE"
echo "PROJECTS_FILE: $PROJECTS_FILE"
echo "Downloads:     $(downloads_dir)"
echo "Backups:       somente projetos listados em auto-code-manager.projects"
echo "Importação:    todos os ZIPs que batem com pasta em /home/daniel/Code"
echo "Intervalo:     ${INTERVAL}s"
echo "Backup cada:   ${BACKUP_EVERY}s"
echo "Zone cada:     ${ZONE_EVERY}s"
echo "Para parar:    Ctrl+C"
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