#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP="$(mktemp -d /tmp/auto-code-light-subproject-config-XXXXXX)"
MANAGER="$TEMP/manager"
CODE_ROOT="$TEMP/Code"
HOME_DIR="$TEMP/home"
STATE="$TEMP/state"
PARENT="$CODE_ROOT/bots/dev-automation"
CHILD="$PARENT/apps/exec-agent"
CONFIG="$PARENT/.config/exec-agent/database.env"
LOG="$TEMP/manager.log"
PID=""

cleanup() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf -- "$TEMP"
}
trap cleanup EXIT

cp -a -- "$ROOT" "$MANAGER"
mkdir -p "$CHILD" "$(dirname -- "$CONFIG")" "$HOME_DIR/Downloads"
printf 'parent-v1\n' > "$PARENT/root.txt"
printf 'child-v1\n' > "$CHILD/app.txt"
cat > "$CONFIG" <<'ENV'
DB_HOST=127.0.0.1
DB_PASSWORD=light-local-secret
ENV

cat > "$MANAGER/config/projects/default.projects" <<'PROJECTS'
bots/dev-automation
bots/dev-automation/apps/exec-agent
PROJECTS
cat > "$MANAGER/config/auto-code-manager.ignore-zip" <<'IGNORE'
.git/
.venv/
venv/
node_modules/
IGNORE
: > "$MANAGER/config/auto-code-manager.ignore-unzip"
: > "$MANAGER/config/auto-code-manager.folder-sql-zip"
cat > "$MANAGER/config/auto-code-manager.env" <<'ENV'
BACKUP_EVERY=1
LIGHT_SCAN_INTERVAL=1
AUTO_CODE_MONITOR_MODE=light
STABLE_WAIT=1
BEEP_MODE=none
BACKUP_BEEP_ENABLED=false
TASKBAR_STATUS_ENABLED=false
ENV

HOME="$HOME_DIR" CODE_ROOT="$CODE_ROOT" AUTO_CODE_STATE_DIR="$STATE" \
  DEV_MANAGER_PROJECTS_FILE="$MANAGER/config/projects/default.projects" \
  "$MANAGER/scripts/auto-code-manager.sh" >"$LOG" 2>&1 &
PID=$!

wait_file() {
  local file="$1" i
  for i in $(seq 1 100); do
    [ -s "$file" ] && return 0
    sleep 0.1
  done
  printf 'FALHOU: ZIP não apareceu: %s\n' "$file" >&2
  cat "$LOG" >&2
  exit 1
}

wait_hash_change() {
  local file="$1" old="$2" i now
  for i in $(seq 1 100); do
    now="$(sha256sum "$file" | awk '{print $1}')"
    [ "$now" != "$old" ] && return 0
    sleep 0.2
  done
  printf 'FALHOU: ZIP não mudou: %s\n' "$file" >&2
  cat "$LOG" >&2
  exit 1
}

PARENT_ZIP="$CODE_ROOT/dev-automation.zip"
CHILD_ZIP="$CODE_ROOT/dev-automation-exec-agent.zip"
wait_file "$PARENT_ZIP"
wait_file "$CHILD_ZIP"
sleep 2

unzip -Z1 "$CHILD_ZIP" | grep -Fxq '.config/exec-agent/database.env'
unzip -p "$CHILD_ZIP" .config/exec-agent/database.env | grep -Fxq 'DB_PASSWORD=********'
! unzip -Z1 "$PARENT_ZIP" | grep -q '^.config/exec-agent/'

parent_before="$(sha256sum "$PARENT_ZIP" | awk '{print $1}')"
child_before="$(sha256sum "$CHILD_ZIP" | awk '{print $1}')"
cat > "$CONFIG" <<'ENV'
DB_HOST=10.0.0.77
DB_PASSWORD=light-local-secret
ENV
wait_hash_change "$CHILD_ZIP" "$child_before"

unzip -p "$CHILD_ZIP" .config/exec-agent/database.env | grep -Fxq 'DB_HOST=10.0.0.77'
unzip -p "$CHILD_ZIP" .config/exec-agent/database.env | grep -Fxq 'DB_PASSWORD=********'
parent_after="$(sha256sum "$PARENT_ZIP" | awk '{print $1}')"
[ "$parent_after" = "$parent_before" ] || {
  printf 'FALHOU: modo light refez ZIP pai por alteração da .config do filho\n' >&2
  cat "$LOG" >&2
  exit 1
}

echo 'OK: modo light atribui .config irmã ao subprojeto e não ao pai'
