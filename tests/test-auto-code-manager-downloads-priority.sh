#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d /tmp/devauto-downloads-priority-XXXXXX)"
trap 'rm -rf -- "$T"' EXIT
PROJECT_ROOT="$ROOT"
CODE_ROOT="$T/Code"
DOWNLOADS_DIR="$T/Downloads"
DEV_MANAGER_PROJECTS_FILE="$T/projects"
mkdir -p "$CODE_ROOT/orgs/alpha" "$CODE_ROOT/orgs/beta" "$DOWNLOADS_DIR"
printf '%s\n' orgs/alpha orgs/beta orgs/later > "$DEV_MANAGER_PROJECTS_FILE"
for module in 00-runtime 40-files-safety 50-project-registry 60-project-runtime 70-imports 130-backups; do
  source "$ROOT/scripts/dev-manager/$module.sh"
done
log() { :; }
run_stage() { shift 3; "$@"; }
wait_if_paused() { :; }
validate_backup_ignore_zip() { return 0; }
stable_file() { return 0; }
backup_order_targets() { printf '%s\n' orgs/alpha orgs/beta; }
configured_download_zip_exists_original="$(declare -f configured_download_zip_exists)"
eval "${configured_download_zip_exists_original/configured_download_zip_exists/configured_download_zip_exists_uncounted}"
SCANS=0
configured_download_zip_exists() { SCANS=$((SCANS + 1)); configured_download_zip_exists_uncounted; }
import_one_zip() { printf 'import:%s\n' "${1##*/}" >> "$T/order"; rm -- "$1"; }
backup_project() {
  printf 'backup:%s\n' "$1" >> "$T/order"
  if [ "$1" = orgs/alpha ]; then
    printf new > "$DOWNLOADS_DIR/alpha--new.zip"
    DOWNLOAD_NEXT_CHECK=0
  fi
}

# Mesmo com muitos eventos de projetos, diretório inalterado não é revarrido.
for ((i=0; i<20; i++)); do
  DOWNLOAD_NEXT_CHECK=0
  downloads_priority_tick
done
[ "$SCANS" -eq 1 ]

# Download que chega durante backup A é importado ANTES do backup de B.
ACTIVE_MONITOR_MODE=inotify
backup_all
printf '%s\n' backup:orgs/alpha import:alpha--new.zip backup:orgs/beta > "$T/expected"
cmp "$T/expected" "$T/order"

# ZIP sem clone só é reconhecido quando a pasta aparece, sem editar o catálogo.
printf new > "$DOWNLOADS_DIR/later--new.zip"
DOWNLOAD_NEXT_CHECK=0
downloads_priority_tick
[ -f "$DOWNLOADS_DIR/later--new.zip" ]
mkdir -p "$CODE_ROOT/orgs/later"
DOWNLOAD_NEXT_CHECK=0
downloads_priority_tick
[ ! -f "$DOWNLOADS_DIR/later--new.zip" ]
printf 'OK: ocioso só consulta metadados; Downloads tem prioridade entre backups e detecta clone novo\n'
