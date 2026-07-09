#!/usr/bin/env bash
set -euo pipefail

CODE_ROOT="/home/daniel/Code"
BACKUP_ROOT="/home/daniel/Code/sind-infra/.backups"

INTERVAL=6
BACKUP_EVERY=300
ZONE_EVERY=30
STABLE_WAIT=2

mkdir -p "$BACKUP_ROOT"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

downloads_dir() {
  if command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
    local win_profile
    win_profile="$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r' || true)"
    [ -n "$win_profile" ] && wslpath "$win_profile/Downloads" 2>/dev/null && return
  fi

  echo "/mnt/c/Users/${USER}/Downloads"
}

stable_file() {
  local f="$1"
  local s1 s2

  [ -f "$f" ] || return 1
  s1="$(stat -c %s "$f" 2>/dev/null || echo 0)"
  sleep "$STABLE_WAIT"
  [ -f "$f" ] || return 1
  s2="$(stat -c %s "$f" 2>/dev/null || echo 0)"

  [ "$s1" = "$s2" ] && [ "$s1" -gt 0 ]
}

project_for_zip() {
  local zipname="$1"
  local p name best=""

  for p in "$CODE_ROOT"/*; do
    [ -d "$p" ] || continue
    name="$(basename "$p")"

    case "$name" in
      .backups|.cache|.idea) continue ;;
    esac

    if [[ "$zipname" == "$name.zip" || "$zipname" == "$name"-*.zip || "$zipname" == "$name"_*.zip ]]; then
      if [ ${#name} -gt ${#best} ]; then
        best="$name"
      fi
    fi
  done

  echo "$best"
}

import_downloads() {
  local dl
  dl="$(downloads_dir)"

  [ -d "$dl" ] || {
    log "Downloads não encontrado: $dl"
    return
  }

  log "Verificando Downloads: $dl"

  find "$dl" -maxdepth 1 -type f -iname "*.zip" -print0 | while IFS= read -r -d '' zipfile; do
    local base project dest moved

    base="$(basename "$zipfile")"
    project="$(project_for_zip "$base")"

    [ -n "$project" ] || {
      log "Ignorando ZIP sem projeto: $base"
      continue
    }

    stable_file "$zipfile" || {
      log "Ainda baixando/gravando: $base"
      continue
    }

    dest="$CODE_ROOT/$project"
    moved="$dest/$base"

    log "Importando $base -> $dest"

    mv -f "$zipfile" "$moved"
    unzip -oq "$moved" -d "$dest"
    rm -f "$moved"

    log "OK: $base extraído em $dest"
  done
}

clean_zone() {
  log "Limpando Zone.Identifier em $CODE_ROOT"

  find "$CODE_ROOT" -type f -name "*:Zone.Identifier" -print -delete 2>/dev/null || true
}

make_backup() {
  local project_dir="$1"
  local name tmp final ignore_file rsync_filter

  name="$(basename "$project_dir")"

  case "$name" in
    .backups|.cache|.idea) return ;;
  esac

  tmp="/tmp/${name}-backup-$$"
  final="$BACKUP_ROOT/${name}.zip"
  ignore_file="$project_dir/.gitignore"
  rsync_filter="/tmp/${name}-gitignore-$$.txt"

  rm -rf "$tmp"
  mkdir -p "$tmp"

  log "Compactando $name"

  if [ -f "$ignore_file" ]; then
    grep -vE '^\s*$|^\s*#' "$ignore_file" > "$rsync_filter"

    rsync -a \
      --exclude-from="$rsync_filter" \
      --exclude=".git/" \
      --exclude="*.zip" \
      "$project_dir/" "$tmp/"
  else
    rsync -a \
      --exclude=".git/" \
      --exclude="*.zip" \
      "$project_dir/" "$tmp/"
  fi

  (
    cd "$tmp"
    zip -qr "$final" .
  )

  rm -rf "$tmp" "$rsync_filter"

  log "Backup gerado: $final"
}

backup_all() {
  log "Gerando backups em $BACKUP_ROOT"

  for project_dir in "$CODE_ROOT"/*; do
    [ -d "$project_dir" ] || continue
    make_backup "$project_dir"
  done
}

last_backup=0
last_zone=0
cycle=1

log "Auto Code Manager iniciado"
log "CODE_ROOT: $CODE_ROOT"
log "BACKUP_ROOT: $BACKUP_ROOT"
log "Intervalo geral: ${INTERVAL}s"
log "Backup a cada: ${BACKUP_EVERY}s"
log "Zone.Identifier a cada: ${ZONE_EVERY}s"

while true; do
  now="$(date +%s)"

  echo "────────────────────────────────────────"
  log "Ciclo #$cycle"

  import_downloads

  if [ $((now - last_zone)) -ge "$ZONE_EVERY" ]; then
    clean_zone
    last_zone="$now"
  fi

  if [ $((now - last_backup)) -ge "$BACKUP_EVERY" ]; then
    backup_all
    last_backup="$now"
  fi

  cycle=$((cycle + 1))
  sleep "$INTERVAL"
done