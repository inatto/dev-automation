#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CODE_ROOT="/home/daniel/Code"
IGNORE_FILE="$SCRIPT_DIR/auto-code-manager.ignore"

INTERVAL=6
BACKUP_EVERY=300
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

    [ -n "$project" ] || {
      log "Ignorando ZIP sem projeto: $zip_name"
      continue
    }

    stable_file "$zip_file" || {
      log "Ainda baixando/gravando: $zip_name"
      continue
    }

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
  local clean_file="$1"

  touch "$IGNORE_FILE"

  sed -E \
    -e 's/\r$//' \
    -e 's/^[[:space:]]+//' \
    -e 's/[[:space:]]+$//' \
    -e '/^[[:space:]]*$/d' \
    -e '/^[[:space:]]*#/d' \
    "$IGNORE_FILE" > "$clean_file"

  {
    echo "*.zip"
    echo "*.log"
    echo "*:Zone.Identifier"
  } >> "$clean_file"

  sort -u "$clean_file" -o "$clean_file"
}

backup_project() {
  local project_dir="$1"
  local project tmp_dir final tmp_zip clean_ignore

  project="$(basename "$project_dir")"

  case "$project" in
    .cache|.idea) return ;;
  esac

  tmp_dir="/tmp/auto-code-manager-$project-$$"
  final="$CODE_ROOT/$project.zip"
  tmp_zip="$CODE_ROOT/.$project.zip.tmp"
  clean_ignore="/tmp/auto-code-manager-ignore-$$.txt"

  rm -rf -- "$tmp_dir"
  rm -f -- "$tmp_zip" "$clean_ignore"
  mkdir -p "$tmp_dir"

  make_clean_ignore "$clean_ignore"

  log "Backup $project -> $final"
  log "Usando ignore: $IGNORE_FILE"

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

[ -d "$CODE_ROOT" ] || {
  echo "ERRO: CODE_ROOT não existe: $CODE_ROOT" >&2
  exit 1
}

touch "$IGNORE_FILE"

line
echo "Auto Code Manager"
line
echo "CODE_ROOT:   $CODE_ROOT"
echo "IGNORE_FILE: $IGNORE_FILE"
echo "Downloads:   $(downloads_dir)"
echo "Backups:     $CODE_ROOT/nome-do-projeto.zip"
echo "Intervalo:   ${INTERVAL}s"
echo "Backup cada: ${BACKUP_EVERY}s"
echo "Zone cada:   ${ZONE_EVERY}s"
echo "Para parar:  Ctrl+C"
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