#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d /tmp/devauto-download-stability-XXXXXX)"
producer=""
cleanup() { [ -z "$producer" ] || wait "$producer" 2>/dev/null || true; rm -rf -- "$T"; }
trap cleanup EXIT
source "$ROOT/scripts/dev-manager/40-files-safety.sh"
STABLE_WAIT=1
printf 'abc' > "$T/file.zip"
stable_file "$T/file.zip"
# Mantém três bytes, mas muda o conteúdo: não pode ser classificado estável.
(sleep 0.2; printf 'xyz' > "$T/file.zip") & producer=$!
if stable_file "$T/file.zip"; then
  echo 'FALHOU: regravação de mesmo tamanho foi aceita como estável' >&2
  exit 1
fi
wait "$producer"; producer=""
# Arquivo vazio, removido ou sem conclusão não pode iniciar a extração.
: > "$T/empty.zip"
! stable_file "$T/empty.zip"
! stable_file "$T/absent.zip"
printf 'OK: estabilidade usa identidade/tamanho/mtime/ctime, incluindo regravação do mesmo tamanho\n'
