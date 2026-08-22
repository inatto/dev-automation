#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CODE_ROOT="$TMP/Code"
PROJECTS_FILE="$TMP/projects"
mkdir -p \
  "$CODE_ROOT/bots/dev-automation" \
  "$CODE_ROOT/infra/amazon-infra" \
  "$CODE_ROOT/orgs/orbital" \
  "$CODE_ROOT/orgs/orbital/orbital-app" \
  "$CODE_ROOT/orgs/orbital/orbital-events"

cat > "$PROJECTS_FILE" <<'PROJECTS'
# comentado/fora
bots/dev-automation
infra/amazon-infra
orgs/orbital.zip
orgs/orbital/orbital-app
orgs/orbital/orbital-events
PROJECTS

actual="$(CODE_ROOT="$CODE_ROOT" PHPSTORMS_PROJECTS_FILE="$PROJECTS_FILE" "$ROOT/scripts/phpstorms.sh" --list)"
expected="$(cat <<EXPECTED
$CODE_ROOT/bots/dev-automation
$CODE_ROOT/infra/amazon-infra
$CODE_ROOT/orgs/orbital/orbital-app
$CODE_ROOT/orgs/orbital/orbital-events
EXPECTED
)"

[[ "$actual" == "$expected" ]] || {
  printf 'FALHOU: phpstorms não preservou lista 1:1.\nEsperado:\n%s\nObtido:\n%s\n' "$expected" "$actual" >&2
  exit 1
}

if grep -q 'target_relative="$group"\|INCLUDE_DEV_AUTOMATION' "$ROOT/scripts/phpstorms.sh"; then
  echo 'FALHOU: lógica antiga de agrupamento/ignore ainda existe' >&2
  exit 1
fi


grep -q 'ConvertFrom-Json -InputObject \$json' "$ROOT/scripts/phpstorms.sh" || {
  echo 'FALHOU: phpstorms não normaliza a lista JSON antes de acessar o primeiro projeto' >&2
  exit 1
}

if grep -Fq '$projects = @($json | ConvertFrom-Json)' "$ROOT/scripts/phpstorms.sh"; then
  echo 'FALHOU: parsing antigo pode aninhar todos os projetos em projects[0] no Windows PowerShell 5.1' >&2
  exit 1
fi
grep -q "dontReopenProjects" "$ROOT/scripts/phpstorms.sh" || {
  echo 'FALHOU: phpstorms não bloqueia o restore automático da sessão anterior' >&2
  exit 1
}

grep -q "function Test-ProjectOpen" "$ROOT/scripts/phpstorms.sh" || {
  echo 'FALHOU: phpstorms não detecta projetos já abertos' >&2
  exit 1
}

grep -q 'Já aberto; ignorando' "$ROOT/scripts/phpstorms.sh" || {
  echo 'FALHOU: phpstorms não ignora projeto já aberto' >&2
  exit 1
}

echo 'OK: phpstorms abre somente projetos reais; agregadores *.zip são ignorados.'
