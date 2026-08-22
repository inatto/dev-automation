#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CODE_ROOT="$TMP/Code"
PROJECTS_FILE="$TMP/projects"
mkdir -p \
  "$CODE_ROOT/bots/dev-automation" \
  "$CODE_ROOT/bots/dev-automation/apps/exec-agent" \
  "$CODE_ROOT/infra/amazon-infra" \
  "$CODE_ROOT/infra/amazon-infra/apps/monitor-app" \
  "$CODE_ROOT/orgs/orbital/orbital-app" \
  "$CODE_ROOT/orgs/orbital/orbital-events"

cat > "$PROJECTS_FILE" <<'PROJECTS'
# comentado/fora
Code.zip
bots/dev-automation
bots/dev-automation/apps/exec-agent
infra/amazon-infra
infra/amazon-infra/apps/monitor-app
orgs/orbital.zip
orgs/orbital/orbital-app
orgs/orbital/orbital-events
PROJECTS

actual="$(CODE_ROOT="$CODE_ROOT" PYCHARMS_PROJECTS_FILE="$PROJECTS_FILE" "$ROOT/scripts/pycharms.sh" --list)"
expected="$(cat <<EXPECTED
$CODE_ROOT/bots/dev-automation
$CODE_ROOT/infra/amazon-infra
$CODE_ROOT/orgs/orbital/orbital-app
$CODE_ROOT/orgs/orbital/orbital-events
EXPECTED
)"

[[ "$actual" == "$expected" ]] || {
  printf 'FALHOU: pycharms não preservou projetos-raiz ou incluiu agregador/subprojeto apps/.\nEsperado:\n%s\nObtido:\n%s\n' "$expected" "$actual" >&2
  exit 1
}

if grep -Fqx "$CODE_ROOT/Code.zip" <<<"$actual" || grep -Fqx "$CODE_ROOT/orgs/orbital.zip" <<<"$actual"; then
  echo 'FALHOU: pycharms tratou agregador *.zip como projeto' >&2
  exit 1
fi

if grep -Fqx "$CODE_ROOT/bots/dev-automation/apps/exec-agent" <<<"$actual" || \
   grep -Fqx "$CODE_ROOT/infra/amazon-infra/apps/monitor-app" <<<"$actual"; then
  echo 'FALHOU: pycharms abriu subprojeto apps/ apesar do projeto-pai estar ativo' >&2
  exit 1
fi

if grep -q 'target_relative="$group"\|INCLUDE_DEV_AUTOMATION' "$ROOT/scripts/pycharms/windows.sh"; then
  echo 'FALHOU: lógica antiga de agrupamento/ignore ainda existe' >&2
  exit 1
fi


grep -q 'ConvertFrom-Json -InputObject \$json' "$ROOT/scripts/pycharms/windows.sh" || {
  echo 'FALHOU: pycharms não normaliza a lista JSON antes de acessar o primeiro projeto' >&2
  exit 1
}

if grep -Fq '$projects = @($json | ConvertFrom-Json)' "$ROOT/scripts/pycharms/windows.sh"; then
  echo 'FALHOU: parsing antigo pode aninhar todos os projetos em projects[0] no Windows PowerShell 5.1' >&2
  exit 1
fi
grep -Fq 'C:\Program Files\JetBrains\PyCharm 2026.2.1\bin\pycharm64.exe' "$ROOT/scripts/pycharms/windows.sh" || {
  echo 'FALHOU: pycharms não prioriza o executável solicitado' >&2
  exit 1
}

grep -q "dontReopenProjects" "$ROOT/scripts/pycharms/windows.sh" || {
  echo 'FALHOU: pycharms não bloqueia o restore automático da sessão anterior' >&2
  exit 1
}

grep -q "function Test-ProjectOpen" "$ROOT/scripts/pycharms/windows.sh" || {
  echo 'FALHOU: pycharms não detecta projetos já abertos' >&2
  exit 1
}

grep -q 'Já aberto; ignorando' "$ROOT/scripts/pycharms/windows.sh" || {
  echo 'FALHOU: pycharms não ignora projeto já aberto' >&2
  exit 1
}

echo 'OK: pycharms abre somente projetos-raiz, ignora agregadores *.zip e subprojetos apps/ cobertos pelo pai.'
