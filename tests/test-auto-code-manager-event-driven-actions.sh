#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP="$(mktemp -d /tmp/auto-code-event-actions-XXXXXX)"
TEST_PROJECT="$TEMP/manager"
CODE_ROOT="$TEMP/Code"
TEST_HOME="$TEMP/home"
PROJECT_DIR="$CODE_ROOT/orgs/alpha-app"
SQL_DIR="$PROJECT_DIR/exports/ddl"
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

cp -a -- "$ROOT" "$TEST_PROJECT"
mkdir -p "$SQL_DIR"
printf 'old\n' > "$PROJECT_DIR/value.txt"

cat > "$TEST_PROJECT/config/auto-code-manager.projects" <<'PROJECTS'
orgs/alpha-app
PROJECTS
cat > "$TEST_PROJECT/config/auto-code-manager.ignore-zip" <<'IGNORE'
.git/
.venv/
venv/
node_modules/
*.log
*:Zone.Identifier
IGNORE
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"
printf '%s\n' "$SQL_DIR" > "$TEST_PROJECT/config/auto-code-manager.folder-sql-zip"
cat > "$TEST_PROJECT/config/auto-code-manager.env" <<'ENV'
BACKUP_EVERY=2
STABLE_WAIT=1
BEEP_REPEATS=1
BEEP_GAP_MS=1
BEEP_MODE=none
BEEP_VOLUME=0
BACKUP_BEEP_ENABLED=false
BACKUP_BEEP_VOLUME=0
TASKBAR_STATUS_ENABLED=false
AUTO_CODE_MONITOR_MODE=inotify
ENV

HOME="$TEST_HOME" CODE_ROOT="$CODE_ROOT" AUTO_CODE_STATE_DIR="$TEMP/state" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" >"$LOG" 2>&1 &
PID=$!

wait_until() {
  local description="$1"
  shift
  local i
  for i in $(seq 1 160); do
    if "$@"; then
      return 0
    fi
    sleep 0.1
  done
  printf 'FALHOU: %s\n' "$description" >&2
  cat "$LOG" >&2
  exit 1
}

zone_present() { [ -e "$PROJECT_DIR/test.txt:Zone.Identifier" ]; }

wait_until 'baseline alpha.zip' test -s "$CODE_ROOT/alpha-app.zip"
wait_until 'watcher event-driven ativo' grep -Fq 'IDLE event-driven' "$LOG"

# SQL não tem mais automação destrutiva. Ele permanece no projeto e apenas
# dispara o backup normal do projeto como qualquer outro arquivo.
before_sql_zip_mtime="$(stat -c %Y "$CODE_ROOT/alpha-app.zip")"
printf 'select 1 from dual;\n' > "$TEMP/event.sql"
mv "$TEMP/event.sql" "$SQL_DIR/event.sql"
wait_until 'SQL preservado no projeto' test -f "$SQL_DIR/event.sql"
wait_until 'backup normal atualizado após SQL' bash -c '[ "$(stat -c %Y "$1")" -gt "$2" ]' _ "$CODE_ROOT/alpha-app.zip" "$before_sql_zip_mtime"
[ -z "$(find "$SQL_DIR" -maxdepth 1 -type f -name '????????-????.zip' -print -quit)" ] || {
  printf 'FALHOU: manager gerou ZIP SQL automático\n' >&2
  exit 1
}

# Linux nativo: Zone.Identifier não recebe tratamento especial.
printf 'zone\n' > "$PROJECT_DIR/test.txt:Zone.Identifier"
wait_until 'Zone.Identifier preservado no Linux nativo' zone_present

# Em idle não deve haver nova rodada de scan.
zone_scans_before="$(grep -Fc 'Limpando Zone.Identifier em' "$LOG" || true)"
sleep 3
zone_scans_after="$(grep -Fc 'Limpando Zone.Identifier em' "$LOG" || true)"
[ "$zone_scans_after" = "$zone_scans_before" ] || {
  printf 'FALHOU: Zone.Identifier voltou a ser varrido em idle\n' >&2
  cat "$LOG" >&2
  exit 1
}

! grep -Fq 'SQL detectado pelo filesystem' "$LOG"
grep -Fq 'projetos geram ZIP local' "$LOG"

printf 'OK: SQL é preservado e só dispara backup normal; Linux nativo ignora Zone.Identifier\n'
