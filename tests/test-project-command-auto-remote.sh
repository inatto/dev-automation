#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP="$(mktemp -d /tmp/project-command-auto-remote-XXXXXX)"
MANAGER="$TEMP/manager"
CODE_ROOT="$TEMP/Code"
HOME_DIR="$TEMP/home"
STATE="$TEMP/state"
APP="$CODE_ROOT/orgs/alpha-app"
AUTO_PID=""

cleanup() {
  if [[ -n "$AUTO_PID" ]] && kill -0 "$AUTO_PID" 2>/dev/null; then
    kill -TERM "$AUTO_PID" 2>/dev/null || true
    wait "$AUTO_PID" 2>/dev/null || true
  fi
  rm -rf -- "$TEMP"
}
trap cleanup EXIT

cp -a -- "$ROOT" "$MANAGER"
mkdir -p "$APP/deploy/remote" "$HOME_DIR/Downloads" "$STATE"
touch "$STATE/dev-manager.sound-disabled"

cat > "$MANAGER/config/projects/default.projects" <<'PROJECTS'
orgs/alpha-app
PROJECTS
cat > "$MANAGER/config/auto-code-manager.ignore-zip" <<'IGNORE'
.git/
.venv/
venv/
node_modules/
*.log
*:Zone.Identifier
IGNORE
: > "$MANAGER/config/auto-code-manager.ignore-unzip"
: > "$MANAGER/config/auto-code-manager.folder-sql-zip"

cat > "$APP/deploy/remote/setup.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
COUNT_FILE="${COUNT_FILE:?}"
n=0
[[ ! -f "$COUNT_FILE" ]] || n="$(cat "$COUNT_FILE")"
printf '%d\n' "$((n + 1))" > "$COUNT_FILE"
printf 'deploy remoto %d\n' "$((n + 1))"
SCRIPT
chmod +x "$APP/deploy/remote/setup.sh"

COUNT_FILE="$TEMP/count" AUTO_CODE_STATE_DIR="$STATE" DEV_AUTOMATION_ERROR_SOUND_ENABLED=0 \
  "$MANAGER/scripts/project-command.sh" remote-alpha-app-auto "$APP" remote >"$TEMP/remote.log" 2>&1 &
AUTO_PID=$!

wait_count() {
  local want="$1" i
  for i in $(seq 1 120); do
    [[ "$(cat "$TEMP/count" 2>/dev/null || true)" == "$want" ]] && return 0
    sleep 0.05
  done
  cat "$TEMP/remote.log" >&2 || true
  return 1
}

wait_count 1
kill -0 "$AUTO_PID"
state_file="$(find "$STATE/running-projects" -maxdepth 1 -type f -name '*.state' -print -quit)"
grep -Fxq 'AUTO_MODE=1' "$state_file"
grep -Fxq 'DEPLOY_MODE=remote' "$state_file"
grep -Fq 'AUTO ativo; aguardando novo ZIP aplicado pelo Dev Automation.' "$TEMP/remote.log"

# Alteração manual não pode refazer o deploy.
printf 'manual\n' > "$APP/manual.txt"
sleep 0.3
[[ "$(cat "$TEMP/count")" == "1" ]]

make_zip() {
  local value="$1"
  rm -rf "$TEMP/pkg" "$TEMP/alpha-app.zip"
  mkdir -p "$TEMP/pkg/config"
  printf '%s\n' "$value" > "$TEMP/pkg/config/runtime.conf"
  (cd "$TEMP/pkg" && zip -qr "$TEMP/alpha-app.zip" .)
}

import_zip() {
  HOME="$HOME_DIR" CODE_ROOT="$CODE_ROOT" AUTO_CODE_STATE_DIR="$STATE" \
    DEV_MANAGER_PROJECTS_FILE="$MANAGER/config/projects/default.projects" AUTO_CODE_TUI=off \
    "$MANAGER/scripts/auto-code-manager.sh" --import-one "$TEMP/alpha-app.zip" >"$TEMP/import.log" 2>&1
}

make_zip v1
import_zip
wait_count 2
grep -Fq 'AUTO: reinício solicitado para orgs/alpha-app (remote' "$TEMP/import.log"

make_zip v2
import_zip
wait_count 3
kill -0 "$AUTO_PID"

kill -TERM "$AUTO_PID"
wait "$AUTO_PID" 2>/dev/null || true
AUTO_PID=""
[[ ! -e "$state_file" ]]

printf 'OK: remote auto persiste após deploy e reexecuta somente por ZIP confirmado\n'
