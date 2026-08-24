#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP="$(mktemp -d /tmp/auto-code-ddl-watch-XXXXXX)"
MANAGER="$TEMP/manager"
CODE_ROOT="$TEMP/Code"
HOME_DIR="$TEMP/home"
STATE_DIR="$TEMP/state"
PROJECT="$CODE_ROOT/infra/oracle-infra"
DDL="$PROJECT/exports/ddl"
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

command -v inotifywait >/dev/null 2>&1 || {
  printf 'SKIP: inotifywait não instalado\n'
  exit 0
}

cp -a -- "$ROOT" "$MANAGER"
mkdir -p "$DDL" "$HOME_DIR" "$STATE_DIR"
printf 'infra/oracle-infra\n' > "$MANAGER/config/auto-code-manager.projects"
: > "$MANAGER/config/auto-code-manager.folder-sql-zip"
printf '%s\n' "$DDL" > "$MANAGER/config/auto-code-manager.folder-sql-watch"
cat > "$MANAGER/config/auto-code-manager.ignore-zip" <<'IGNORE'
.git/
.venv/
venv/
node_modules/
*.log
*.tmp
exports/ddl/*-ddl-*.zip
*:Zone.Identifier
IGNORE
: > "$MANAGER/config/auto-code-manager.ignore-unzip"
cat > "$MANAGER/config/auto-code-manager.env" <<'ENV'
BACKUP_EVERY=1
STABLE_WAIT=1
LIGHT_SCAN_INTERVAL=1
BEEP_REPEATS=1
BEEP_GAP_MS=1
BEEP_MODE=none
BEEP_VOLUME=0
BACKUP_BEEP_ENABLED=false
BACKUP_BEEP_VOLUME=0
TASKBAR_STATUS_ENABLED=false
AUTO_CODE_MONITOR_MODE=inotify
ENV

start_manager() {
  HOME="$HOME_DIR" CODE_ROOT="$CODE_ROOT" AUTO_CODE_STATE_DIR="$STATE_DIR" AUTO_CODE_TUI=off \
    "$MANAGER/scripts/auto-code-manager.sh" >"$LOG" 2>&1 &
  PID=$!
}

stop_manager() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  PID=""
}

wait_until() {
  local description="$1"
  shift
  local i
  for i in $(seq 1 240); do
    if "$@"; then
      return 0
    fi
    sleep 0.1
  done
  printf 'FALHOU: %s\n' "$description" >&2
  cat "$LOG" >&2
  exit 1
}

snapshot_count_local() {
  find "$DDL" -maxdepth 1 -type f -name 'oracle-infra-ddl-*.zip' | wc -l | tr -d ' '
}

snapshot_count_root() {
  find "$CODE_ROOT" -maxdepth 1 -type f -name 'oracle-infra-ddl-*.zip' | wc -l | tr -d ' '
}

start_manager
wait_until 'manager entrou em idle' grep -Fq 'IDLE event-driven' "$LOG"

printf 'create table a (id number);\n' > "$DDL/a.sql"
wait_until 'snapshot local após novo SQL' bash -c '[ "$(find "$1" -maxdepth 1 -type f -name "oracle-infra-ddl-*.zip" | wc -l)" -ge 1 ]' _ "$DDL"
wait_until 'snapshot espelhado no CODE_ROOT' bash -c '[ "$(find "$1" -maxdepth 1 -type f -name "oracle-infra-ddl-*.zip" | wc -l)" -ge 1 ]' _ "$CODE_ROOT"

local_zip="$(find "$DDL" -maxdepth 1 -type f -name 'oracle-infra-ddl-*.zip' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
root_zip="$CODE_ROOT/$(basename -- "$local_zip")"
test -f "$DDL/a.sql"
cmp -s -- "$local_zip" "$root_zip"
unzip -tq "$local_zip" >/dev/null
unzip -Z1 "$local_zip" | grep -Fx 'a.sql' >/dev/null

before="$(snapshot_count_local)"
printf 'create table a (id number, name varchar2(30));\n' > "$DDL/a.sql"
printf 'create table b (id number);\n' > "$DDL/b.sql"
wait_until 'novo snapshot após alteração DDL' bash -c '[ "$(find "$1" -maxdepth 1 -type f -name "oracle-infra-ddl-*.zip" | wc -l)" -gt "$2" ]' _ "$DDL" "$before"
wait_until 'snapshot espelhado após alteração' test -f "$CODE_ROOT/$(basename -- "$(find "$DDL" -maxdepth 1 -type f -name 'oracle-infra-ddl-*.zip' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)")"

latest="$(find "$DDL" -maxdepth 1 -type f -name 'oracle-infra-ddl-*.zip' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
latest_root="$CODE_ROOT/$(basename -- "$latest")"
test -f "$DDL/a.sql"
test -f "$DDL/b.sql"
cmp -s -- "$latest" "$latest_root"
unzip -Z1 "$latest" | grep -Fx 'a.sql' >/dev/null
unzip -Z1 "$latest" | grep -Fx 'b.sql' >/dev/null
unzip -p "$latest" a.sql | grep -Fq 'name varchar2(30)'

# O backup normal do projeto não incorpora snapshots DDL, evitando ZIP dentro de ZIP.
wait_until 'backup normal atualizado' test -s "$CODE_ROOT/oracle-infra.zip"
! unzip -Z1 "$CODE_ROOT/oracle-infra.zip" | grep -E '^exports/ddl/oracle-infra-ddl-.*\.zip$' >/dev/null

# Reiniciar sem alterar SQL não cria snapshot duplicado: assinatura persistida.
stop_manager
count_before_restart="$(snapshot_count_local)"
: > "$LOG"
start_manager
wait_until 'manager reiniciado em idle' grep -Fq 'IDLE event-driven' "$LOG"
sleep 2
[ "$(snapshot_count_local)" = "$count_before_restart" ]
[ "$(snapshot_count_root)" = "$count_before_restart" ]

if grep -Fq 'OK SQL SNAPSHOT:' "$LOG"; then
  printf 'FALHOU: reinício sem mudança gerou snapshot novo\n' >&2
  cat "$LOG" >&2
  exit 1
fi

printf 'OK: DDL novo/alterado gera snapshot não destrutivo na pasta e cópia idêntica em CODE_ROOT; reinício sem mudança é idempotente\n'
