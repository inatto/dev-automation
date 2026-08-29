#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP="$(mktemp -d /tmp/auto-code-runtime-no-auto-XXXXXX)"
MANAGER="$TEMP/manager"
CODE_ROOT="$TEMP/Code"
HOME_DIR="$TEMP/home"
STATE="$TEMP/state"
APP="$CODE_ROOT/orgs/alpha-app"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  rm -rf -- "$TEMP"
}
trap cleanup EXIT

cp -a -- "$ROOT" "$MANAGER"
mkdir -p "$APP/apps/api" "$APP/deploy/local" "$HOME_DIR/Downloads" "$STATE"
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

cat > "$APP/deploy/local/setup.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
COUNT_FILE="${COUNT_FILE:?}"
n=0
[[ ! -f "$COUNT_FILE" ]] || n="$(cat "$COUNT_FILE")"
printf '%d\n' "$((n + 1))" > "$COUNT_FILE"
trap 'exit 0' TERM INT
while true; do sleep 0.1; done
SCRIPT
chmod +x "$APP/deploy/local/setup.sh"

COUNT_FILE="$TEMP/count" AUTO_CODE_STATE_DIR="$STATE" DEV_AUTOMATION_ERROR_SOUND_ENABLED=0 \
  "$MANAGER/scripts/project-command.sh" alpha-app "$APP" local setup >"$TEMP/app.log" 2>&1 &
APP_PID=$!

wait_count() {
  local want="$1" i
  for i in $(seq 1 100); do
    [[ "$(cat "$TEMP/count" 2>/dev/null || true)" == "$want" ]] && return 0
    sleep 0.05
  done
  cat "$TEMP/app.log" >&2 || true
  return 1
}
wait_count 1
state_file="$(find "$STATE/running-projects" -maxdepth 1 -type f -name '*.state' -print -quit)"
grep -Fxq 'AUTO_MODE=0' "$state_file"

mkdir -p "$TEMP/pkg/apps/api"
printf 'novo\n' > "$TEMP/pkg/apps/api/main.py"
(cd "$TEMP/pkg" && zip -qr "$TEMP/alpha-app.zip" .)
HOME="$HOME_DIR" CODE_ROOT="$CODE_ROOT" AUTO_CODE_STATE_DIR="$STATE" \
  DEV_MANAGER_PROJECTS_FILE="$MANAGER/config/projects/default.projects" AUTO_CODE_TUI=off \
  "$MANAGER/scripts/auto-code-manager.sh" --import-one "$TEMP/alpha-app.zip" >"$TEMP/import.log" 2>&1

sleep 0.4
[[ "$(cat "$TEMP/count")" == "1" ]]
grep -Fq 'AUTO: nenhum deploy auto ativo para orgs/alpha-app.' "$TEMP/import.log"

# Edição manual também não dispara nada: project-command não observa filesystem.
printf 'manual\n' > "$APP/manual.txt"
sleep 0.3
[[ "$(cat "$TEMP/count")" == "1" ]]

printf 'OK: comando normal e edição manual não recebem reinício automático\n'
