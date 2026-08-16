#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d /tmp/auto-code-download-batch-test-XXXXXX)"
TEST_PROJECT="$TEMP_ROOT/dev-automation"
CODE_ROOT="$TEMP_ROOT/Code"
WORKER_FROM_DIR="$TEMP_ROOT/worker/from"
LOG_FILE="$TEMP_ROOT/import-batch.log"
FAKE_BIN="$TEMP_ROOT/fake-bin"

cleanup() {
  rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT

cp -a -- "$PROJECT_ROOT" "$TEST_PROJECT"
mkdir -p \
  "$CODE_ROOT/orgs/alpha-app" \
  "$CODE_ROOT/orgs/beta-app" \
  "$WORKER_FROM_DIR" \
  "$FAKE_BIN"

cat > "$FAKE_BIN/powershell.exe" <<'PS'
#!/usr/bin/env bash
exit 0
PS
chmod +x "$FAKE_BIN/powershell.exe"

alpha_package="$TEMP_ROOT/alpha-package"
beta_package="$TEMP_ROOT/beta-package"
mkdir -p "$alpha_package" "$beta_package"
printf 'alpha novo\n' > "$alpha_package/value.txt"
printf 'beta novo\n' > "$beta_package/value.txt"
(
  cd "$alpha_package"
  zip -q "$WORKER_FROM_DIR/alpha-app(2).zip" value.txt
)
(
  cd "$beta_package"
  zip -q "$WORKER_FROM_DIR/beta-app%2323.zip" value.txt
)


# ZIP sem correspondência no .projects deve ser completamente ignorado.
printf 'rom qualquer\n' > "$TEMP_ROOT/unrelated.txt"
(
  cd "$TEMP_ROOT"
  zip -q "$WORKER_FROM_DIR/The Goonies (1986) Konami [MSX].zip" unrelated.txt
)

cat > "$TEST_PROJECT/config/auto-code-manager.projects" <<'PROJECTS'
orgs/alpha-app
orgs/beta-app
PROJECTS
: > "$TEST_PROJECT/config/auto-code-manager.ignore-zip"
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"
cat > "$TEST_PROJECT/config/auto-code-manager.env" <<'ENV'
STABLE_WAIT=1
INTERVAL=1
ZONE_EVERY=1
BACKUP_EVERY=60
BEEP_REPEATS=1
BEEP_GAP_MS=1
BEEP_MODE=none
BEEP_VOLUME=0
BACKUP_BEEP_ENABLED=false
ENV

PATH="$FAKE_BIN:$PATH" \
CODE_ROOT="$CODE_ROOT" \
WORKER_FROM_DIR="$WORKER_FROM_DIR" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" --import-downloads-once > "$LOG_FILE" 2>&1

grep -Fxq 'alpha novo' "$CODE_ROOT/orgs/alpha-app/value.txt"
grep -Fxq 'beta novo' "$CODE_ROOT/orgs/beta-app/value.txt"
[ ! -e "$WORKER_FROM_DIR/alpha-app(2).zip" ]
[ ! -e "$WORKER_FROM_DIR/beta-app%2323.zip" ]
[ -e "$WORKER_FROM_DIR/The Goonies (1986) Konami [MSX].zip" ]

grep -Fq 'LOTE DE WORKER/FROM: 2 ZIP(s)' "$LOG_FILE"
grep -Fq 'LOTE [1/2]:' "$LOG_FILE"
grep -Fq 'LOTE [2/2]:' "$LOG_FILE"
grep -Fq 'LOTE DE WORKER/FROM CONCLUÍDO: 2 sucesso(s), 0 falha(s), 2 processado(s).' "$LOG_FILE"


# Falha de um ZIP reconhecido deve continuar retornando erro, mas o arquivo
# precisa sair de worker/from para não ser reprocessado indefinidamente.
printf 'isto nao e um zip\n' > "$WORKER_FROM_DIR/alpha-app-corrompido.zip"
if PATH="$FAKE_BIN:$PATH" \
CODE_ROOT="$CODE_ROOT" \
WORKER_FROM_DIR="$WORKER_FROM_DIR" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" --import-downloads-once >> "$LOG_FILE" 2>&1; then
  echo 'ERRO: lote com ZIP corrompido deveria retornar falha' >&2
  exit 1
fi
[ ! -e "$WORKER_FROM_DIR/alpha-app-corrompido.zip" ]
grep -Fq 'ERRO: ZIP inválido ou corrompido. O ZIP foi mantido.' "$LOG_FILE"
grep -Fq 'ZIP com falha apagado para evitar reprocessamento:' "$LOG_FILE"

printf 'OK: todos os ZIPs de worker/from são processados em sequência e falhas saem da fila sem loop\n'
