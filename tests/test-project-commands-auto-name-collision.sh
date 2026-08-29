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
  "$CODE_ROOT/orgs/foo/deploy/local" \
  "$CODE_ROOT/orgs/foo-auto/deploy/local"
: > "$HOME_DIR/.bashrc"

cat > "$PROJECTS_FILE" <<'PROJECTS'
orgs/foo
orgs/foo-auto
PROJECTS

for path in \
  "$CODE_ROOT/orgs/foo/deploy/local/setup.sh" \
  "$CODE_ROOT/orgs/foo-auto/deploy/local/setup.sh"; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$path"
  chmod +x "$path"
done

set +e
HOME="$HOME_DIR" TARGET_DIR="$TARGET_DIR" CODE_ROOT="$CODE_ROOT" PROJECTS_FILE="$PROJECTS_FILE" \
  "$ROOT/deploy/local/install-project-commands.sh" >"$TMP/out.log" 2>&1
status=$?
set -e

[[ "$status" -ne 0 ]]
grep -Fq "nome de comando global ambíguo foo-auto" "$TMP/out.log"
[[ ! -e "$TARGET_DIR/foo" ]]
[[ ! -e "$TARGET_DIR/foo-auto" ]]

printf 'OK: sufixo -auto reservado não colide com nome real de outro projeto\n'
