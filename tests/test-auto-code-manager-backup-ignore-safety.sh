#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
TEST_PROJECT="$TMP/dev-automation"
CODE_ROOT="$TMP/Code"

cp -a -- "$ROOT" "$TEST_PROJECT"
mkdir -p "$CODE_ROOT/orgs/sample-app"
printf 'data\n' > "$CODE_ROOT/orgs/sample-app/file.txt"
printf 'orgs/sample-app\n' > "$TEST_PROJECT/config/projects/default.projects"

# Ausente: deve bloquear e não recriar vazio.
rm -f "$TEST_PROJECT/config/auto-code-manager.ignore-zip"
set +e
CODE_ROOT="$CODE_ROOT" "$TEST_PROJECT/scripts/auto-code-manager.sh" --backup-once >"$TMP/missing.log" 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ ! -e "$CODE_ROOT/sample-app.zip" ]]
[[ ! -e "$TEST_PROJECT/config/auto-code-manager.ignore-zip" ]]
grep -Fq 'ERRO DE SEGURANÇA: ignore global de ZIP não existe' "$TMP/missing.log"

# Vazio: também bloqueia.
: > "$TEST_PROJECT/config/auto-code-manager.ignore-zip"
set +e
CODE_ROOT="$CODE_ROOT" "$TEST_PROJECT/scripts/auto-code-manager.sh" --backup-once >"$TMP/empty.log" 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ ! -e "$CODE_ROOT/sample-app.zip" ]]
grep -Fq 'ignore global de ZIP está vazio' "$TMP/empty.log"

# Sem regra crítica: bloqueia.
printf '.git/\n.venv/\nvenv/\n' > "$TEST_PROJECT/config/auto-code-manager.ignore-zip"
set +e
CODE_ROOT="$CODE_ROOT" "$TEST_PROJECT/scripts/auto-code-manager.sh" --backup-once >"$TMP/invalid.log" 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ ! -e "$CODE_ROOT/sample-app.zip" ]]
grep -Fq 'regra obrigatória ausente no ignore global de ZIP: node_modules/' "$TMP/invalid.log"

# Mínimo seguro: backup funciona.
cat > "$TEST_PROJECT/config/auto-code-manager.ignore-zip" <<'IGNORE'
.git/
.venv/
venv/
node_modules/
IGNORE
CODE_ROOT="$CODE_ROOT" "$TEST_PROJECT/scripts/auto-code-manager.sh" --backup-once >"$TMP/safe.log" 2>&1
[[ -s "$CODE_ROOT/sample-app.zip" ]]

printf 'OK: backup aborta com ignore global ausente, vazio ou sem regras críticas\n'
