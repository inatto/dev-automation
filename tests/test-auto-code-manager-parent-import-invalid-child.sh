#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d /tmp/auto-code-parent-invalid-test-XXXXXX)"
TEST_PROJECT="$TEMP_ROOT/dev-automation"
CODE_ROOT="$TEMP_ROOT/Code"
PACKAGE_DIR="$TEMP_ROOT/package"
CHILD_DIR="$TEMP_ROOT/child"
PARENT_ZIP="$TEMP_ROOT/orbital.zip"
MANAGER="$TEST_PROJECT/scripts/auto-code-manager.sh"
LOG_FILE="$TEMP_ROOT/import-invalid.log"

cleanup() {
  rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT

cp -a -- "$PROJECT_ROOT" "$TEST_PROJECT"
mkdir -p \
  "$CODE_ROOT/orgs/orbital/orbital-app" \
  "$CODE_ROOT/orgs/orbital/orbital-assets" \
  "$PACKAGE_DIR" \
  "$CHILD_DIR"

printf 'original app\n' > "$CODE_ROOT/orgs/orbital/orbital-app/app.txt"
printf 'app novo que não deve entrar\n' > "$CHILD_DIR/app.txt"
(
  cd "$CHILD_DIR"
  zip -q "$PACKAGE_DIR/orbital-app.zip" app.txt
)
printf 'isto não é zip\n' > "$PACKAGE_DIR/orbital-assets.zip"
(
  cd "$PACKAGE_DIR"
  zip -q -0 "$PARENT_ZIP" orbital-app.zip orbital-assets.zip
)

cat > "$TEST_PROJECT/config/auto-code-manager.projects" <<'PROJECTS'
orgs/orbital/orbital-app
orgs/orbital/orbital-assets
PROJECTS

: > "$TEST_PROJECT/config/auto-code-manager.ignore-zip"
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"
cat > "$TEST_PROJECT/config/auto-code-manager.env" <<'ENV'
STABLE_WAIT=1
INTERVAL=1
ZONE_EVERY=1
BACKUP_EVERY=1
BEEP_REPEATS=1
BEEP_GAP_MS=1
BEEP_MODE=none
BEEP_VOLUME=0
ENV

if CODE_ROOT="$CODE_ROOT" "$MANAGER" --import-one "$PARENT_ZIP" >"$LOG_FILE" 2>&1; then
  echo 'FALHOU: importação deveria falhar com ZIP filho inválido' >&2
  cat "$LOG_FILE" >&2
  exit 1
fi

[ -e "$PARENT_ZIP" ] || {
  echo 'FALHOU: ZIP pai inválido foi apagado' >&2
  exit 1
}

grep -Fxq 'original app' "$CODE_ROOT/orgs/orbital/orbital-app/app.txt"
[ ! -e "$CODE_ROOT/orgs/orbital/orbital-app/app-new.txt" ]
grep -Fq 'Nenhum ZIP filho foi importado; ZIP pai mantido' "$LOG_FILE"

printf 'OK: ZIP filho inválido mantém o ZIP pai e não altera módulos\n'
