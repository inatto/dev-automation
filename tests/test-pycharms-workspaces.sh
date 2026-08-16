#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/pycharms-workspaces-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

CODE="$TMP/Code"
STATE="$TMP/state"
CFG="$TMP/projects"
mkdir -p "$CODE/bots/dev-automation" "$CODE/orgs/orbital/orbital-app" "$CODE/infra/amazon-infra/apps/monitor-app"
cat > "$CFG" <<'PROJECTS'
bots/dev-automation
orgs/missing-project
orgs/orbital/orbital-app
infra/amazon-infra
infra/amazon-infra/apps/monitor-app
PROJECTS

# Criar apps/monitor-app cria fisicamente o pai amazon-infra; como o pai está
# cadastrado e existe, ele é o projeto efetivo e o filho não duplica a IDE.
MAP="$(CODE_ROOT="$CODE" AUTO_CODE_STATE_DIR="$STATE" PYCHARMS_PROJECTS_FILE="$CFG" PYCHARMS_PLATFORM=ubuntu "$ROOT/scripts/pycharms.sh" --workspace-map 2>/dev/null)"
EXPECTED=$(cat <<EOF_EXPECTED
2	dev-automation	$CODE/bots/dev-automation
4	orbital-app	$CODE/orgs/orbital/orbital-app
5	amazon-infra	$CODE/infra/amazon-infra
EOF_EXPECTED
)
[[ "$MAP" == "$EXPECTED" ]] || {
  printf 'FALHOU: mapa projeto/workspace inesperado\nEsperado:\n%s\nRecebido:\n%s\n' "$EXPECTED" "$MAP" >&2
  exit 1
}

EXT="$ROOT/apps/pycharms-gnome-extension/extension.js"
grep -q 'change_workspace_by_index(target.workspace - 1, false)' "$EXT" || { echo 'FALHOU: extensão não move para workspace específico' >&2; exit 1; }
grep -q 'move_to_monitor' "$EXT" || { echo 'FALHOU: extensão não move para monitor 4K/maior área' >&2; exit 1; }
grep -q 'MaximizeFlags.BOTH' "$EXT" || { echo 'FALHOU: extensão não maximiza' >&2; exit 1; }
if grep -q 'window.activate(global.get_current_time())' "$EXT"; then
  echo 'FALHOU: extensão ativa a janela e pode trocar o workspace atual do usuário' >&2
  exit 1
fi
grep -q "workspaces.tsv" "$EXT" || { echo 'FALHOU: extensão não lê mapa de workspaces' >&2; exit 1; }

echo 'OK: pycharms usa a mesma posição de desktops (1=LAZER, 2+=config), ignora ausentes para abrir, move cada projeto ao workspace correto, manda ao maior monitor e não ativa/troca o workspace atual.'
