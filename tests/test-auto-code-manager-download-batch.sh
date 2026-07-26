#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d /tmp/auto-code-download-batch-test-XXXXXX)"
TEST_PROJECT="$TEMP_ROOT/dev-automation"
CODE_ROOT="$TEMP_ROOT/Code"
DOWNLOADS_DIR="$TEMP_ROOT/Downloads"
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
  "$DOWNLOADS_DIR" \
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
  zip -q "$DOWNLOADS_DIR/alpha-app(2).zip" value.txt
)
(
  cd "$beta_package"
  zip -q "$DOWNLOADS_DIR/beta-app%2323.zip" value.txt
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
DOWNLOADS_DIR="$DOWNLOADS_DIR" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" --import-downloads-once > "$LOG_FILE" 2>&1

grep -Fxq 'alpha novo' "$CODE_ROOT/orgs/alpha-app/value.txt"
grep -Fxq 'beta novo' "$CODE_ROOT/orgs/beta-app/value.txt"
[ ! -e "$DOWNLOADS_DIR/alpha-app(2).zip" ]
[ ! -e "$DOWNLOADS_DIR/beta-app%2323.zip" ]

grep -Fq 'LOTE DE DOWNLOADS: 2 ZIP(s)' "$LOG_FILE"
grep -Fq 'LOTE [1/2]:' "$LOG_FILE"
grep -Fq 'LOTE [2/2]:' "$LOG_FILE"
grep -Fq 'LOTE DE DOWNLOADS CONCLUÍDO: 2 sucesso(s), 0 falha(s), 2 processado(s).' "$LOG_FILE"

printf 'OK: todos os ZIPs de Downloads são processados em sequência na mesma rodada\n'
