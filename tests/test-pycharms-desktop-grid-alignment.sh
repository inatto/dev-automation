#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/pycharms-grid-alignment-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT

CODE="$TMP/Code"
CFG="$TMP/projects"
STATE="$TMP/state"
mkdir -p "$CODE/bots/dev-automation/apps/amazon-imap-bot" \
         "$CODE/orgs/after-child" \
         "$CODE/infra/last-project"
cat > "$CFG" <<'PROJECTS'
bots/dev-automation
bots/dev-automation/apps/amazon-imap-bot
orgs/after-child
infra/last-project
PROJECTS

MAP="$(CODE_ROOT="$CODE" AUTO_CODE_STATE_DIR="$STATE" PYCHARMS_PROJECTS_FILE="$CFG" PYCHARMS_PLATFORM=ubuntu "$ROOT/scripts/pycharms.sh" --workspace-map 2>/dev/null)"
EXPECTED=$(printf '2\tdev-automation\t%s\n3\tafter-child\t%s\n4\tlast-project\t%s' \
  "$CODE/bots/dev-automation" "$CODE/orgs/after-child" "$CODE/infra/last-project")
[[ "$MAP" == "$EXPECTED" ]] || {
  printf 'FALHOU: PyCharm não usa a mesma grade compacta de desktops/terminals.\nEsperado:\n%s\nRecebido:\n%s\n' "$EXPECTED" "$MAP" >&2
  exit 1
}

echo 'OK: subprojeto apps/ não consome workspace no PyCharm; projetos seguintes permanecem alinhados com desktops/terminals.'
