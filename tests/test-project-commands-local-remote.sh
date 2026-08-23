#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
CODE_ROOT="$TMP/Code"
TARGET_DIR="$HOME_DIR/.local/bin"
APP="$CODE_ROOT/orgs/sample-app"
mkdir -p "$HOME_DIR" "$APP/deploy/local" "$APP/deploy/remote"
: > "$HOME_DIR/.bashrc"
printf 'orgs/sample-app\n' > "$TMP/projects"
for mode in local remote; do
  for script in setup start test start-api setup-web; do
    cat > "$APP/deploy/$mode/$script.sh" <<SCRIPT
#!/usr/bin/env bash
printf '%s:%s:%s\\n' '$mode' '$script' "\${*:-}"
SCRIPT
    chmod +x "$APP/deploy/$mode/$script.sh"
  done
done
HOME="$HOME_DIR" TARGET_DIR="$TARGET_DIR" CODE_ROOT="$CODE_ROOT" PROJECTS_FILE="$TMP/projects" \
  "$ROOT/deploy/local/install-project-commands.sh" >/dev/null
[[ -x "$TARGET_DIR/sample-app" ]]
[[ -x "$TARGET_DIR/remote-sample-app" ]]
[[ -x "$TARGET_DIR/ssh-sample-app" ]]
[[ "$($TARGET_DIR/sample-app | tail -n 1)" == 'local:setup:' ]]
[[ "$($TARGET_DIR/sample-app start | tail -n 1)" == 'local:start:' ]]
[[ "$($TARGET_DIR/remote-sample-app | tail -n 1)" == 'remote:setup:' ]]
[[ "$($TARGET_DIR/remote-sample-app start-api abc | tail -n 1)" == 'remote:start-api:abc' ]]
if "$TARGET_DIR/remote-sample-app help" >/dev/null 2>&1; then
  echo 'FALHOU: help inventado foi aceito' >&2
  exit 1
fi
echo 'OK: comandos locais e remotos executam somente scripts reais do contrato'
