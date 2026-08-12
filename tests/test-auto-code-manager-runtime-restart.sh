#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP="$(mktemp -d /tmp/auto-code-runtime-restart-XXXXXX)"
MANAGER="$TEMP/manager"
CODE_ROOT="$TEMP/Code"
HOME_DIR="$TEMP/home"
STATE="$TEMP/state"
APP="$CODE_ROOT/orgs/alpha-app"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]]; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  rm -rf -- "$TEMP"
}
trap cleanup EXIT

cp -a -- "$ROOT" "$MANAGER"
mkdir -p "$APP/apps/api" "$APP/apps/web" "$APP/deploy/local" "$HOME_DIR/Downloads" "$STATE"
touch "$STATE/dev-manager.sound-disabled"

cat > "$MANAGER/config/auto-code-manager.projects" <<'PROJECTS'
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
cat > "$MANAGER/config/auto-code-manager.env" <<'ENV'
BACKUP_EVERY=1
STABLE_WAIT=1
BEEP_REPEATS=1
BEEP_GAP_MS=1
BEEP_MODE=none
BEEP_VOLUME=0
BACKUP_BEEP_ENABLED=false
BACKUP_BEEP_VOLUME=0
TASKBAR_STATUS_ENABLED=false
ENV

make_runner() {
  local path="$1" count_var="$2"
  cat > "$path" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
COUNT_FILE="\${$count_var:?}"
n=0
[[ ! -f "\$COUNT_FILE" ]] || n="\$(cat "\$COUNT_FILE")"
printf '%d\\n' "\$((n + 1))" > "\$COUNT_FILE"
trap 'exit 0' TERM INT
while true; do sleep 0.1; done
SCRIPT
  chmod +x "$path"
}
make_runner "$APP/deploy/local/setup-api.sh" API_COUNT_FILE
make_runner "$APP/deploy/local/setup-web.sh" WEB_COUNT_FILE
cat > "$APP/deploy/local/setup.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDS=()
cleanup() {
  ((${#PIDS[@]})) && kill "${PIDS[@]}" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT
"$SCRIPT_DIR/setup-api.sh" & PIDS+=("$!")
"$SCRIPT_DIR/setup-web.sh" & PIDS+=("$!")
wait -n "${PIDS[@]}"
SCRIPT
chmod +x "$APP/deploy/local/setup.sh"

API_COUNT_FILE="$TEMP/api.count" WEB_COUNT_FILE="$TEMP/web.count" AUTO_CODE_STATE_DIR="$STATE" DEV_AUTOMATION_ERROR_SOUND_ENABLED=0 \
  "$MANAGER/scripts/project-command.sh" alpha-app "$APP" local setup >"$TEMP/app.log" 2>&1 &
APP_PID=$!

wait_count() {
  local file="$1" want="$2" i
  for i in $(seq 1 120); do
    [[ "$(cat "$file" 2>/dev/null || true)" == "$want" ]] && return 0
    sleep 0.05
  done
  printf 'FALHOU esperando %s=%s\n' "$file" "$want" >&2
  cat "$TEMP/app.log" >&2 || true
  return 1
}
wait_count "$TEMP/api.count" 1
wait_count "$TEMP/web.count" 1
state_file="$(find "$STATE/running-projects" -maxdepth 1 -type f -name '*.state' -print -quit)"
grep -Fxq 'MODE=split' "$state_file"

make_zip() {
  local kind="$1" zip="$TEMP/alpha-app.zip" pkg="$TEMP/pkg"
  rm -rf "$pkg" "$zip"
  mkdir -p "$pkg"
  case "$kind" in
    api) mkdir -p "$pkg/apps/api"; printf 'api\n' > "$pkg/apps/api/main.py" ;;
    web) mkdir -p "$pkg/apps/web/src"; printf 'web\n' > "$pkg/apps/web/src/app.js" ;;
    both) mkdir -p "$pkg/config"; printf 'shared\n' > "$pkg/config/runtime.conf" ;;
  esac
  (cd "$pkg" && zip -qr "$zip" .)
}

import_zip() {
  HOME="$HOME_DIR" CODE_ROOT="$CODE_ROOT" AUTO_CODE_STATE_DIR="$STATE" \
    "$MANAGER/scripts/auto-code-manager.sh" --import-one "$TEMP/alpha-app.zip" >"$TEMP/import.log" 2>&1
  [[ ! -e "$TEMP/alpha-app.zip" ]]
}

make_zip api
import_zip
wait_count "$TEMP/api.count" 2
[[ "$(cat "$TEMP/web.count")" == 1 ]]
grep -Fq 'Escopo de runtime detectado: api' "$TEMP/import.log"

make_zip web
import_zip
wait_count "$TEMP/web.count" 2
[[ "$(cat "$TEMP/api.count")" == 2 ]]
grep -Fq 'Escopo de runtime detectado: web' "$TEMP/import.log"

make_zip both
import_zip
wait_count "$TEMP/api.count" 3
wait_count "$TEMP/web.count" 3
grep -Fq 'Escopo de runtime detectado: both' "$TEMP/import.log"

# A extração acontece em /tmp e deve desaparecer antes de o import retornar.
if find /tmp -maxdepth 1 -type d -name 'auto-code-import-alpha-app-*' -print -quit | grep -q .; then
  printf 'FALHOU: temporário de importação ficou acumulado em /tmp\n' >&2
  exit 1
fi

printf 'OK: ZIP completo reinicia seletivamente API/Web no comando agregado e limpa temporários\n'
