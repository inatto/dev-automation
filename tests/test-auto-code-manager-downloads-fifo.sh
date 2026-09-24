#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d /tmp/devauto-downloads-fifo-XXXXXX)"
trap 'rm -rf -- "$T"' EXIT
PROJECT_ROOT="$ROOT"
CODE_ROOT="$T/Code"
DEV_MANAGER_PROJECTS_FILE="$T/projects"
DOWNLOADS_DIR="$T/z Linux Downloads"
WINDOWS_DOWNLOADS_DIR="$T/a Windows Downloads"
mkdir -p "$CODE_ROOT/orgs/alpha" "$CODE_ROOT/orgs/beta" "$DOWNLOADS_DIR" "$WINDOWS_DOWNLOADS_DIR"
printf '%s\n' orgs/alpha orgs/beta > "$DEV_MANAGER_PROJECTS_FILE"
for module in 00-runtime 40-files-safety 50-project-registry 60-project-runtime 70-imports; do
  source "$ROOT/scripts/dev-manager/$module.sh"
done
is_wsl_runtime() { return 0; }
log() { printf '%s\n' "$*" >> "$T/log"; }
wait_if_paused() { :; }
run_stage() { shift 3; "$@"; }
# A estabilidade é exercitada no teste de integração; aqui isolamos a fila.
stable_file() { [ "${1##*/}" != "${UNSTABLE_NAME:-}" ]; }
import_one_zip() {
  [ "${2:-}" = true ]
  local file="$1" name="${1##*/}"
  printf '%s\n' "$name" >> "$T/order"
  [ "$name" != "${FAIL_NAME:-}" ] || return 1
  if [ "$name" = alpha--z-antigo.zip ] && [ ! -f "$T/late-created" ]; then
    # Surgiu durante A: entra depois de B, já enfileirado, mesmo com mtime antigo.
    printf 'late\n' > "$WINDOWS_DOWNLOADS_DIR/beta--late.zip"
    touch -d '@1700000000.250000000' "$WINDOWS_DOWNLOADS_DIR/beta--late.zip"
    touch "$T/late-created"
  fi
  rm -- "$file"
}

# Todos no MESMO segundo: ordenação deve respeitar nanossegundos e ambas as caixas.
printf old > "$DOWNLOADS_DIR/alpha--z-antigo.zip"
printf new > "$WINDOWS_DOWNLOADS_DIR/alpha--a-novo.zip"
printf noise > "$DOWNLOADS_DIR/manual desconhecido.zip"
printf partial > "$DOWNLOADS_DIR/beta--incompleto.zip.crdownload"
touch -d '@1700000000.100000000' "$DOWNLOADS_DIR/alpha--z-antigo.zip"
touch -d '@1700000000.900000000' "$WINDOWS_DOWNLOADS_DIR/alpha--a-novo.zip"
import_downloads
printf '%s\n' alpha--z-antigo.zip alpha--a-novo.zip beta--late.zip > "$T/expected"
cmp "$T/expected" "$T/order"
[ -f "$DOWNLOADS_DIR/manual desconhecido.zip" ]
[ -f "$DOWNLOADS_DIR/beta--incompleto.zip.crdownload" ]

# Erro na cabeça bloqueia a nova versão e não entra em loop no timer.
: > "$T/order"
printf bad > "$DOWNLOADS_DIR/alpha--bad.zip"
printf new > "$DOWNLOADS_DIR/alpha--next.zip"
touch -d '@1700000010' "$DOWNLOADS_DIR/alpha--bad.zip"
touch -d '@1700000011' "$DOWNLOADS_DIR/alpha--next.zip"
FAIL_NAME=alpha--bad.zip
if import_downloads; then
  echo 'FALHOU: corrupção deveria pausar a fila' >&2
  exit 1
fi
[ "$(cat "$T/order")" = alpha--bad.zip ]
[ -f "$DOWNLOADS_DIR/alpha--next.zip" ]
downloads_priority_tick true
[ "$(wc -l < "$T/order")" -eq 1 ]
# Corrigir/substituir o arquivo libera a cabeça; nenhum mais novo passou antes.
printf corrected > "$DOWNLOADS_DIR/alpha--bad.zip"
# O mtime mudou para agora, mas a posição anterior permanece reservada.
FAIL_NAME=""
downloads_priority_tick true
printf '%s\n' alpha--bad.zip alpha--bad.zip alpha--next.zip > "$T/expected"
cmp "$T/expected" "$T/order"

# Escrita em curso: sem falsa contagem de sucesso e sem ultrapassar a cabeça.
: > "$T/order"
printf wait > "$DOWNLOADS_DIR/alpha--wait.zip"
printf later > "$DOWNLOADS_DIR/beta--later.zip"
touch -d '@1700000020' "$DOWNLOADS_DIR/alpha--wait.zip"
touch -d '@1700000021' "$DOWNLOADS_DIR/beta--later.zip"
UNSTABLE_NAME=alpha--wait.zip
import_downloads
[ ! -s "$T/order" ]
[ "$DOWNLOAD_RETRY_PENDING" = true ]
UNSTABLE_NAME=""
downloads_priority_tick true
printf '%s\n' alpha--wait.zip beta--later.zip > "$T/expected"
cmp "$T/expected" "$T/order"

printf 'OK: FIFO global/nanossegundos, chegadas durante importação, arquivos alheios/parciais e bloqueio seguro em erro\n'
