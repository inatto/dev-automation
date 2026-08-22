#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
HOME_DIR="$TMP/home"
CODE_ROOT="$TMP/Code"
TARGET_DIR="$HOME_DIR/.local/bin"
PROJECTS_FILE="$TMP/projects"
mkdir -p "$HOME_DIR" "$TARGET_DIR" \
  "$CODE_ROOT/orgs/alpha/apps/exec-agent/deploy/local" \
  "$CODE_ROOT/orgs/beta/tools/exec-agent/deploy/local"
: > "$HOME_DIR/.bashrc"

cat > "$PROJECTS_FILE" <<'PROJECTS'
orgs/alpha/apps/exec-agent
orgs/beta/tools/exec-agent
PROJECTS

for path in \
  "$CODE_ROOT/orgs/alpha/apps/exec-agent/deploy/local/setup.sh" \
  "$CODE_ROOT/orgs/beta/tools/exec-agent/deploy/local/setup.sh"; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$path"
  chmod +x "$path"
done

set +e
HOME="$HOME_DIR" TARGET_DIR="$TARGET_DIR" CODE_ROOT="$CODE_ROOT" PROJECTS_FILE="$PROJECTS_FILE" \
  "$ROOT/deploy/local/install-project-commands.sh" >"$TMP/out.log" 2>&1
status=$?
set -e

[[ "$status" -ne 0 ]]
grep -Fq 'nome lógico de projeto duplicado' "$TMP/out.log"
[[ ! -e "$TARGET_DIR/exec-agent" ]]
[[ ! -e "$TARGET_DIR/local-all" ]]

printf 'OK: instalador de comandos aborta antes de criar atalhos quando a chave lógica se repete\n'
