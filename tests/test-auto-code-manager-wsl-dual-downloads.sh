#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d /tmp/devauto-wsl-dual-downloads-XXXXXX)"
PID=""
cleanup(){
  if [ -n "$PID" ]; then
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf -- "$T"
}
trap cleanup EXIT

M="$T/manager"
C="$T/Code"
H="$T/home"
DL="$H/Downloads"
DW="$T/mnt-c/Users/daniel/Downloads"
S="$T/state"
P="$C/orgs/alpha-app"
cp -a -- "$ROOT" "$M"
mkdir -p "$P" "$DL" "$DW" "$S"
touch "$S/dev-manager.sound-disabled"
printf 'old\n' > "$P/app.txt"

cat > "$M/config/projects/default.projects" <<'CFG'
orgs/alpha-app
CFG
cat > "$M/config/auto-code-manager.ignore-zip" <<'CFG'
.git/
.venv/
venv/
node_modules/
*.log
*:Zone.Identifier
CFG
: > "$M/config/auto-code-manager.ignore-unzip"
: > "$M/config/auto-code-manager.folder-sql-zip"
cat > "$M/config/auto-code-manager.env" <<'CFG'
AUTO_CODE_MONITOR_MODE=inotify
BACKUP_EVERY=1
STABLE_WAIT=1
BEEP_REPEATS=1
BEEP_GAP_MS=1
BEEP_MODE=none
BACKUP_BEEP_ENABLED=false
TASKBAR_STATUS_ENABLED=false
CFG

run(){
  HOME="$H" WSL_DISTRO_NAME=Ubuntu DOWNLOADS_DIR="$DL" WINDOWS_DOWNLOADS_DIR="$DW" \
    CODE_ROOT="$C" AUTO_CODE_STATE_DIR="$S" DEV_MANAGER_PROJECTS_FILE="$M/config/projects/default.projects" AUTO_CODE_TUI=off \
    "$M/scripts/auto-code-manager.sh" "$@"
}

# Uma única drenagem deve enxergar ZIPs nas duas caixas.
mkdir -p "$T/pkg-linux" "$T/pkg-win"
printf 'linux\n' > "$T/pkg-linux/app.txt"
(cd "$T/pkg-linux" && zip -qr "$DL/alpha-app--linux.zip" .)
run --import-downloads-once >/dev/null
[ "$(cat "$P/app.txt")" = linux ]
[ ! -e "$DL/alpha-app--linux.zip" ]

printf 'windows-once\n' > "$T/pkg-win/app.txt"
(cd "$T/pkg-win" && zip -qr "$DW/alpha-app--windows-once.zip" .)
run --import-downloads-once >/dev/null
[ "$(cat "$P/app.txt")" = windows-once ]
[ ! -e "$DW/alpha-app--windows-once.zip" ]

# Runtime: o Downloads Windows não depende de inotify. O loop acorda em até 1s
# e detecta a alteração por varredura rasa, simulando arquivo criado pelo Chrome.
LOG="$T/live.log"
HOME="$H" WSL_DISTRO_NAME=Ubuntu DOWNLOADS_DIR="$DL" WINDOWS_DOWNLOADS_DIR="$DW" \
  CODE_ROOT="$C" AUTO_CODE_STATE_DIR="$S" DEV_MANAGER_PROJECTS_FILE="$M/config/projects/default.projects" AUTO_CODE_TUI=off \
  "$M/scripts/auto-code-manager.sh" >"$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 150); do
  grep -Fq 'IDLE event-driven' "$LOG" 2>/dev/null && break
  sleep .1
done
grep -Fq 'IDLE event-driven' "$LOG"
grep -Fq 'por varredura rasa de 1s' "$LOG"

rm -rf "$T/pkg-live"; mkdir -p "$T/pkg-live"
printf 'windows-live\n' > "$T/pkg-live/app.txt"
(cd "$T/pkg-live" && zip -qr "$T/alpha-app--windows-live.zip" .)
mv "$T/alpha-app--windows-live.zip" "$DW/"

for _ in $(seq 1 150); do
  [ "$(cat "$P/app.txt")" = windows-live ] && [ ! -e "$DW/alpha-app--windows-live.zip" ] && break
  sleep .1
done
[ "$(cat "$P/app.txt")" = windows-live ]
[ ! -e "$DW/alpha-app--windows-live.zip" ]

kill -TERM "$PID" 2>/dev/null || true
sleep .2
kill -KILL "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
PID=""

printf 'OK: WSL monitora/importa ~/Downloads e Downloads do Windows; pasta Windows funciona sem depender de inotify\n'
