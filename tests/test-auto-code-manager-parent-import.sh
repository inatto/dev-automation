#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d /tmp/auto-code-parent-import-test-XXXXXX)"
TEST_PROJECT="$TEMP_ROOT/dev-automation"
CODE_ROOT="$TEMP_ROOT/Code"
PACKAGE_DIR="$TEMP_ROOT/package"
PARENT_ZIP="$TEMP_ROOT/orbital(7).zip"
MANAGER="$TEST_PROJECT/scripts/auto-code-manager.sh"
LOG_FILE="$TEMP_ROOT/import.log"
MODULES=(orbital-app orbital-assets orbital-fin orbital-mail orbital-reports)

cleanup() {
  rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT

cp -a -- "$PROJECT_ROOT" "$TEST_PROJECT"
mkdir -p "$PACKAGE_DIR"

for module in "${MODULES[@]}"; do
  child_dir="$TEMP_ROOT/child-$module"
  mkdir -p "$CODE_ROOT/orgs/orbital/$module" "$child_dir"
  printf 'conteúdo novo de %s\n' "$module" > "$child_dir/module.txt"
  (
    cd "$child_dir"
    zip -q "$PACKAGE_DIR/$module.zip" module.txt
  )
done

printf 'arquivo antigo preservado\n' > "$CODE_ROOT/orgs/orbital/orbital-app/old.txt"
(
  cd "$PACKAGE_DIR"
  zip -q -0 "$PARENT_ZIP" ./*.zip
)

cat > "$TEST_PROJECT/config/projects/default.projects" <<'PROJECTS'
orgs/orbital.zip
orgs/orbital/orbital-app
orgs/orbital/orbital-assets
orgs/orbital/orbital-fin
orgs/orbital/orbital-mail
orgs/orbital/orbital-reports
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

CODE_ROOT="$CODE_ROOT" "$MANAGER" --import-one "$PARENT_ZIP" >"$LOG_FILE" 2>&1

[ ! -e "$PARENT_ZIP" ] || {
  echo 'FALHOU: ZIP pai não foi removido após sucesso completo' >&2
  cat "$LOG_FILE" >&2
  exit 1
}

for module in "${MODULES[@]}"; do
  grep -Fxq "conteúdo novo de $module" "$CODE_ROOT/orgs/orbital/$module/module.txt"
done

grep -Fxq 'arquivo antigo preservado' "$CODE_ROOT/orgs/orbital/orbital-app/old.txt"

if find "$CODE_ROOT/orgs/orbital" -maxdepth 1 -type f -iname '*.zip' | grep -q .; then
  echo 'FALHOU: ZIPs filhos ficaram soltos dentro de orgs/orbital' >&2
  find "$CODE_ROOT/orgs/orbital" -maxdepth 1 -type f -iname '*.zip' >&2
  exit 1
fi

grep -Fq 'Todos os 5 ZIP(s) filho(s) foram validados antes da importação.' "$LOG_FILE"
grep -Fq '5 ZIP(s) filho(s) importado(s) e confirmado(s).' "$LOG_FILE"

printf 'OK: orbital.zip extraiu os cinco ZIPs filhos nos módulos e preservou arquivos existentes do módulo\n'
