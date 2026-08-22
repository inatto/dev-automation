#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d /tmp/auto-code-download-drain-test-XXXXXX)"
trap 'rm -rf -- "$TEMP_ROOT"' EXIT

TEST_PROJECT="$TEMP_ROOT/dev-automation"
CODE_ROOT="$TEMP_ROOT/Code"
DOWNLOADS_DIR="$TEMP_ROOT/Downloads"
LOG_FILE="$TEMP_ROOT/import.log"

cp -a -- "$PROJECT_ROOT" "$TEST_PROJECT"
mkdir -p "$CODE_ROOT/orgs/alpha" "$CODE_ROOT/orgs/beta" "$DOWNLOADS_DIR"

cat > "$TEST_PROJECT/config/auto-code-manager.projects" <<'PROJECTS'
orgs/alpha
orgs/beta
PROJECTS
: > "$TEST_PROJECT/config/auto-code-manager.ignore-zip"
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"

make_zip() {
  local project="$1" value="$2" out="$3" tmp
  tmp="$(mktemp -d "$TEMP_ROOT/pkg-XXXXXX")"
  printf '%s\n' "$value" > "$tmp/value.txt"
  (cd "$tmp" && zip -q "$out" value.txt)
  rm -rf -- "$tmp"
}

# O primeiro ZIP já existe quando a drenagem começa.
make_zip alpha 'alpha novo' "$DOWNLOADS_DIR/alpha--primeiro.zip"

# O segundo aparece DURANTE a primeira importação. Para simular isso sem
# depender de timing do inotify, adicionamos um pequeno atraso na confirmação
# da primeira cópia e criamos beta em paralelo.
(
  sleep 0.2
  make_zip beta 'beta novo' "$DOWNLOADS_DIR/beta--segundo.zip"
) &
producer=$!

# Carrega as funções e substitui apenas a importação por uma operação mínima,
# preservando a lógica real de seleção/revarredura da fila.
PROJECT_ROOT="$TEST_PROJECT"
source "$TEST_PROJECT/scripts/dev-manager/00-runtime.sh"
source "$TEST_PROJECT/scripts/dev-manager/20-status-logging.sh"
source "$TEST_PROJECT/scripts/dev-manager/40-files-safety.sh"
source "$TEST_PROJECT/scripts/dev-manager/50-project-registry.sh"
source "$TEST_PROJECT/scripts/dev-manager/60-project-runtime.sh"
source "$TEST_PROJECT/scripts/dev-manager/70-imports.sh"

wait_if_paused() { :; }
soft_beep() { :; }
line() { :; }
log() { printf '%s\n' "$*" >> "$LOG_FILE"; }
download_zip_has_purpose() { return 0; }

import_one_zip() {
  local zip_file="$1" name target
  name="$(basename -- "$zip_file")"
  case "$name" in
    alpha--*) target="$CODE_ROOT/orgs/alpha" ;;
    beta--*) target="$CODE_ROOT/orgs/beta" ;;
    *) return 1 ;;
  esac
  # Mantém alpha ocupado tempo suficiente para beta surgir na pasta.
  [[ "$name" == alpha--* ]] && sleep 0.5
  unzip -oq "$zip_file" -d "$target"
  rm -f -- "$zip_file"
}

export CODE_ROOT DOWNLOADS_DIR
import_downloads
wait "$producer"

grep -Fxq 'alpha novo' "$CODE_ROOT/orgs/alpha/value.txt"
grep -Fxq 'beta novo' "$CODE_ROOT/orgs/beta/value.txt"
[ ! -e "$DOWNLOADS_DIR/alpha--primeiro.zip" ]
[ ! -e "$DOWNLOADS_DIR/beta--segundo.zip" ]
grep -Fq 'FILA DE DOWNLOADS [1]:' "$LOG_FILE"
grep -Fq 'FILA DE DOWNLOADS [2]:' "$LOG_FILE"
grep -Fq 'FILA DE DOWNLOADS DRENADA: 2 sucesso(s), 0 falha(s), 2 processado(s).' "$LOG_FILE"

printf 'OK: Downloads é drenado até vazio, inclusive ZIP que chega durante outra importação\n'
