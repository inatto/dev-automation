#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CODE="$TMP/Code"
CFG="$TMP/projects"
mkdir -p "$CODE/bots/dev-automation/apps/exec-agent" "$CODE/orgs/orbital/orbital-app" "$CODE/infra/standalone/apps/child"
cat > "$CFG" <<'PROJECTS'
bots/dev-automation
bots/dev-automation/apps/exec-agent
bots/missing
orgs/orbital/orbital-app
orgs/orbital/missing
infra/standalone/apps/child
PROJECTS

expected=$(printf '%s\n' \
  "$CODE/bots/dev-automation" \
  "$CODE/orgs/orbital/orbital-app" \
  "$CODE/infra/standalone/apps/child")

for platform in ubuntu windows; do
  out="$(CODE_ROOT="$CODE" PYCHARMS_PROJECTS_FILE="$CFG" PYCHARMS_PLATFORM="$platform" "$ROOT/scripts/pycharms.sh" --list 2>/dev/null)"
  [[ "$out" == "$expected" ]] || {
    printf 'FALHOU backend %s\nEsperado:\n%s\nRecebido:\n%s\n' "$platform" "$expected" "$out" >&2
    exit 1
  }
done

echo 'OK: pycharms lista somente projetos cadastrados que existem no grid efetivo; ausentes ficam fora e subprojeto apps/ não duplica pai ativo.'
