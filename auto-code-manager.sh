#!/usr/bin/env bash
set -euo pipefail

CODE_ROOT="/home/daniel/Code"
GLOBAL_IGNORE="$CODE_ROOT/auto-code-manager.ignore"

INTERVAL_SECONDS=6
BACKUP_EVERY_SECONDS=300
ZONE_EVERY_SECONDS=30
STABLE_WAIT_SECONDS=2

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

is_stable_file() {
  local file="$1"
  local s1 s2

  [ -f "$file" ] || return 1

  s1="$(stat -c %s "$file" 2>/dev/null || echo 0)"
  sleep "$STABLE_WAIT_SECONDS"
  [ -f "$file" ] || return 1
  s2="$(stat -c %s "$file" 2>/dev/null || echo 0)"

  [ "$s1" = "$s2" ] && [ "$s1" -gt 0 ]
}

project_for_zip() {
  local zip_name="$1"
  local dir project best=""

  for dir in "$CODE_ROOT"/*; do
    [ -d "$dir" ] || continue

    project="$(basename "$dir")"

    case "$project" in
      .backups|.cache|.idea) continue ;;
    esac

    if [[ "$zip_name" == "$project.zip" || "$zip_name" == "$project"-*.zip || "$zip_name" == "$project"_*.zip ]]; then
      if [ ${#project} -gt ${#best} ]; then
        best="$project"
      fi
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
      log "Ignorando ZIP sem projeto: $zip_name"
      continue
    fi

    if ! is_stable_file "$zip_file"; then
      log "Ainda baixando/gravando: $zip_name"
      continue
    fi

    project_dir="$CODE_ROOT/$project"
    target="$project_dir/$zip_name"

    log "Importando $zip_name -> $project_dir"

    mv -f -- "$zip_file" "$target"
    unzip -oq -- "$target" -d "$project_dir"
    rm -f -- "$target"

    log "OK: $zip_name extraído."
  done
}

clean_zone_identifier() {
  log "Limpando Zone.Identifier em $CODE_ROOT"

  find "$CODE_ROOT" -type f -name "*:Zone.Identifier" -print -delete 2>/dev/null || true
}

add_ignore_file() {
  local file="$1"
  local output="$2"

  [ -f "$file" ] || return

  sed -E \
    -e 's/^[[:space:]]+//' \
    -e 's/[[:space:]]+$//' \
    -e '/^[[:space:]]*$/d' \
    -e '/^[[:space:]]*#/d' \
    -e '/^[[:space:]]*!/d' \
    "$file" >> "$output" || true
}

make_exclude_file() {
  local project_dir="$1"
  local output="$2"

  rm -f -- "$output"

  {
    echo ".git/"
    echo "*.zip"
    echo "*.log"
    echo "*:Zone.Identifier"
  } > "$output"

  add_ignore_file "$GLOBAL_IGNORE" "$output"
  add_ignore_file "$project_dir/.gitignore" "$output"

  sort -u "$output" -o "$output"
}

backup_project() {
  local project_dir="$1"
  local project tmp_dir exclude_file final_zip tmp_zip

  project="$(basename "$project_dir")"

  case "$project" in
    .backups|.cache|.idea) return ;;
  esac

  tmp_dir="/tmp/auto-code-manager-$project-$$"
  exclude_file="/tmp/auto-code-manager-$project.ignore"
  final_zip="$CODE_ROOT/$project.zip"
  tmp_zip="$CODE_ROOT/.$project.zip.tmp"

  rm -rf -- "$tmp_dir"
  rm -f -- "$tmp_zip" "$exclude_file"
  mkdir -p "$tmp_dir"

  make_exclude_file "$project_dir" "$exclude_file"

  log "Backup $project -> $final_zip"

  rsync -a --exclude-from="$exclude_file" "$project_dir/" "$tmp_dir/"

  (
    cd "$tmp_dir"
    zip -qr "$tmp_zip" .
  )

  mv -f -- "$tmp_zip" "$final_zip"

  rm -rf -- "$tmp_dir" "$exclude_file"

  log "OK backup: $final_zip"
}

backup_all() {
  local dir

  log "Gerando backups em $CODE_ROOT"

  for dir in "$CODE_ROOT"/*; do
    [ -d "$dir" ] || continue
    backup_project "$dir"
  done
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

touch "$GLOBAL_IGNORE"

line
echo "Auto Code Manager"
line
echo "CODE_ROOT:        $CODE_ROOT"
echo "GLOBAL_IGNORE:    $GLOBAL_IGNORE"
echo "Downloads:        $(downloads_dir)"
echo "Backup:           $CODE_ROOT/nome-do-projeto.zip"
echo "Intervalo:        ${INTERVAL_SECONDS}s"
echo "Backup a cada:    ${BACKUP_EVERY_SECONDS}s"
echo "Zone a cada:      ${ZONE_EVERY_SECONDS}s"
echo "Para parar:       Ctrl+C"
line

cycle=1
last_backup=0
last_zone=0

while true; do
  now="$(date +%s)"

  line
  log "Ciclo #$cycle"

  import_downloads

  if [ $((now - last_zone)) -ge "$ZONE_EVERY_SECONDS" ]; then
    clean_zone_identifier
    last_zone="$now"
  fi

  if [ $((now - last_backup)) -ge "$BACKUP_EVERY_SECONDS" ]; then
    backup_all
    last_backup="$now"
  fi

  cycle=$((cycle + 1))
  sleep "$INTERVAL_SECONDS"
done