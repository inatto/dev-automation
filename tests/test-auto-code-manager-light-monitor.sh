#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP="$(mktemp -d /tmp/auto-code-light-monitor-XXXXXX)"
TEST_PROJECT="$TEMP/manager"
CODE_ROOT="$TEMP/Code"
HOME_DIR="$TEMP/home"
DOWNLOADS="$HOME_DIR/Downloads"
STATE="$TEMP/state"
PROJECT="$CODE_ROOT/orgs/alpha-app"
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

cp -a -- "$ROOT" "$TEST_PROJECT"
mkdir -p "$PROJECT" "$DOWNLOADS"
cat > "$TEST_PROJECT/config/auto-code-manager.projects" <<'CFG'
orgs/alpha-app
CFG
cat > "$TEST_PROJECT/config/auto-code-manager.ignore-zip" <<'CFG'
.git/
.venv/
venv/
node_modules/
*.log
*:Zone.Identifier
CFG
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"
: > "$TEST_PROJECT/config/auto-code-manager.folder-sql-zip"
cat > "$TEST_PROJECT/config/auto-code-manager.env" <<'CFG'
BACKUP_EVERY=1
LIGHT_SCAN_INTERVAL=1
AUTO_CODE_MONITOR_MODE=light
STABLE_WAIT=1
BEEP_MODE=none
BACKUP_BEEP_ENABLED=false
TASKBAR_STATUS_ENABLED=false
CFG

printf 'node_modules/\nignored-by-git/\n' > "$PROJECT/.gitignore"
printf 'v1\n' > "$PROJECT/app.txt"
(
  cd "$PROJECT"
  git init -q
  git add .gitignore app.txt
  git -c user.name=test -c user.email=test@example.invalid commit -qm init
)

HOME="$HOME_DIR" CODE_ROOT="$CODE_ROOT" AUTO_CODE_STATE_DIR="$STATE" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" >"$LOG" 2>&1 &
PID=$!

wait_until() {
  local description="$1"
  shift
  local i
  for i in $(seq 1 120); do
    if "$@"; then return 0; fi
    sleep 0.1
  done
  echo "FALHOU: $description" >&2
  cat "$LOG" >&2
  exit 1
}

wait_until 'backup baseline' test -s "$CODE_ROOT/alpha-app.zip"
wait_until 'modo light ativo' grep -Fq 'IDLE leve' "$LOG"

before="$(sha256sum "$CODE_ROOT/alpha-app.zip" | awk '{print $1}')"
printf 'v2\n' > "$PROJECT/app.txt"
changed="$before"
for _i in $(seq 1 80); do
  changed="$(sha256sum "$CODE_ROOT/alpha-app.zip" | awk '{print $1}')"
  [ "$changed" != "$before" ] && break
  sleep 0.2
done
[ "$changed" != "$before" ] || { echo 'FALHOU: alteração real não foi detectada' >&2; exit 1; }

# Diretório globalmente ignorado criado depois do monitor subir não pode sujar backup.
mkdir -p "$PROJECT/node_modules/pkg"
printf cache > "$PROJECT/node_modules/pkg/cache.txt"
sleep 3
[ "$(sha256sum "$CODE_ROOT/alpha-app.zip" | awk '{print $1}')" = "$changed" ] || {
  echo 'FALHOU: node_modules disparou backup no modo light' >&2
  exit 1
}

# O mesmo vale para diretório coberto por .gitignore já existente.
mkdir -p "$PROJECT/ignored-by-git/sub"
printf cache > "$PROJECT/ignored-by-git/sub/cache.txt"
sleep 3
[ "$(sha256sum "$CODE_ROOT/alpha-app.zip" | awk '{print $1}')" = "$changed" ] || {
  echo 'FALHOU: diretório do .gitignore disparou backup no modo light' >&2
  exit 1
}

# Downloads continua automático no mesmo loop leve.
pkg="$TEMP/pkg"
mkdir -p "$pkg"
printf 'fromzip\n' > "$pkg/app.txt"
(cd "$pkg" && zip -q "$DOWNLOADS/alpha-app.zip" app.txt)
wait_until 'ZIP importado' grep -Fxq fromzip "$PROJECT/app.txt"
wait_until 'ZIP apagado' test ! -e "$DOWNLOADS/alpha-app.zip"

# O processo do manager não pode consumir instância inotify no modo light.
for fd in /proc/$PID/fd/*; do
  [ "$(readlink "$fd" 2>/dev/null || true)" != 'anon_inode:inotify' ] || {
    echo 'FALHOU: manager abriu inotify no modo light' >&2
    exit 1
  }
done

printf 'OK: modo light detecta mudança real, poda ignores dinâmicos, importa Downloads e usa zero inotify\n'
