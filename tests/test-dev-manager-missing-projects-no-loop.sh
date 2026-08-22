#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/Code/bots/dev-automation" "$TMP/state"
printf '%s\n' \
  'bots/dev-automation' \
  'bots/general-crawler' \
  'orgs/orbital/orbital-app' > "$TMP/projects"

export AUTO_CODE_STATE_DIR="$TMP/state"
export CODE_ROOT="$TMP/Code"
PROJECT_ROOT="$ROOT"
source "$ROOT/scripts/dev-manager/00-runtime.sh" 2>/dev/null || true
# O patch é testado em isolamento; fornecemos apenas primitivas necessárias.
PROJECTS_FILE="$TMP/projects"
IGNORE_ZIP_FILE="$TMP/ignore"
: > "$IGNORE_ZIP_FILE"
log() { printf '%s\n' "$*" >> "$TMP/log"; }
wait_if_paused() { :; }
target_is_aggregate() { [[ "${1,,}" == *.zip ]]; }
target_is_code_aggregate() { [[ "${1,,}" == code.zip ]]; }
project_path() { printf '%s/%s\n' "$CODE_ROOT" "$1"; }
backup_targets() { cat "$PROJECTS_FILE"; }
validate_backup_ignore_zip() { return 0; }
aggregate_depends_on_project() { return 1; }
backup_order_targets() { backup_targets; }
DIRTY_BACKUP_TARGETS=()
declare -A DIRTY_BACKUP_TARGETS
LAST_SOURCE_CHANGE=0

source "$ROOT/scripts/dev-manager/160-dirty-backups.sh"

calls="$TMP/calls"
: > "$calls"
backup_project() { printf '%s\n' "$1" >> "$calls"; return 0; }

DIRTY_BACKUP_TARGETS['bots/dev-automation']=1
DIRTY_BACKUP_TARGETS['bots/general-crawler']=1
DIRTY_BACKUP_TARGETS['orgs/orbital/orbital-app']=1
LAST_SOURCE_CHANGE="$(date +%s)"

backup_dirty_targets

grep -Fxq 'bots/dev-automation' "$calls"
[[ "$(wc -l < "$calls")" -eq 1 ]]
[[ "${#DIRTY_BACKUP_TARGETS[@]}" -eq 0 ]]

# Rodar de novo sem qualquer alteração não pode gerar outro backup.
backup_dirty_targets
[[ "$(wc -l < "$calls")" -eq 1 ]]

echo 'OK: projeto ausente é descartado da fila; backup não entra em loop sem alteração.'
