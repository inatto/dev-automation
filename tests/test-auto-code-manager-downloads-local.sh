#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d /tmp/devauto-downloads-local-XXXXXX)"
PID=""
cleanup(){ [ -z "$PID" ] || { kill -TERM "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; }; rm -rf -- "$T"; }
trap cleanup EXIT
M="$T/manager"; C="$T/Code"; H="$T/home"; D="$H/Downloads"; S="$T/state"; P="$C/orgs/alpha-app"
cp -a -- "$ROOT" "$M"
mkdir -p "$P" "$D" "$S"
printf 'old\n' > "$P/app.txt"
cat > "$M/config/auto-code-manager.projects" <<'EOF'
orgs/alpha-app
EOF
cat > "$M/config/auto-code-manager.ignore-zip" <<'EOF'
.git/
.venv/
venv/
node_modules/
*.log
*:Zone.Identifier
EOF
: > "$M/config/auto-code-manager.ignore-unzip"
: > "$M/config/auto-code-manager.folder-sql-zip"
cat > "$M/config/auto-code-manager.env" <<'EOF'
AUTO_CODE_MONITOR_MODE=inotify
BACKUP_EVERY=1
STABLE_WAIT=1
BEEP_REPEATS=1
BEEP_GAP_MS=1
BEEP_MODE=none
BACKUP_BEEP_ENABLED=false
TASKBAR_STATUS_ENABLED=false
EOF
run(){ HOME="$H" DOWNLOADS_DIR="$D" CODE_ROOT="$C" AUTO_CODE_STATE_DIR="$S" AUTO_CODE_TUI=off "$M/scripts/auto-code-manager.sh" "$@"; }
[ "$(run --identify-zip "$D/alpha-app--fix.zip")" = 'orgs/alpha-app' ]
printf x > "$T/x"; (cd "$T" && zip -q "$D/unknown.zip" x); run --import-downloads-once >/dev/null; [ -f "$D/unknown.zip" ]
mkdir "$T/pkg"; printf 'new\n' > "$T/pkg/app.txt"; (cd "$T/pkg" && zip -qr "$D/alpha-app--fix.zip" .)
run --import-downloads-once >/dev/null
[ "$(cat "$P/app.txt")" = new ]; [ ! -e "$D/alpha-app--fix.zip" ]; unzip -p "$C/alpha-app.zip" app.txt | grep -Fxq old

# .remover: o marcador recebido nunca fica no projeto; ele remove apenas o par alvo.
printf 'legacy\n' > "$P/obsolete.txt"
mkdir -p "$T/remove-pkg"
: > "$T/remove-pkg/obsolete.txt.remover"
printf 'keep\n' > "$T/remove-pkg/keep.txt"
(cd "$T/remove-pkg" && zip -qr "$D/alpha-app--remove.zip" .)
run --import-downloads-once >/dev/null
[ ! -e "$P/obsolete.txt" ]
[ ! -e "$P/obsolete.txt.remover" ]
[ "$(cat "$P/keep.txt")" = keep ]
[ ! -e "$D/alpha-app--remove.zip" ]

python3 - "$D/alpha-app--unsafe.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z: z.writestr('../escape.txt', 'bad')
PY
if run --import-downloads-once >/dev/null 2>&1; then exit 1; fi
[ -e "$D/alpha-app--unsafe.zip" ]; [ ! -e "$T/escape.txt" ]; rm -f "$D/alpha-app--unsafe.zip"
printf 'before-live\n' > "$P/app.txt"
LOG="$T/live.log"
HOME="$H" DOWNLOADS_DIR="$D" CODE_ROOT="$C" AUTO_CODE_STATE_DIR="$S" AUTO_CODE_TUI=off "$M/scripts/auto-code-manager.sh" >"$LOG" 2>&1 & PID=$!
for _ in $(seq 1 100); do grep -Fq 'IDLE event-driven' "$LOG" 2>/dev/null && break; sleep .1; done
grep -Fq 'IDLE event-driven' "$LOG"
mkdir "$T/live"; printf 'live\n' > "$T/live/app.txt"; (cd "$T/live" && zip -qr "$T/alpha-app--live.zip" .); mv "$T/alpha-app--live.zip" "$D/"
for _ in $(seq 1 120); do [ "$(cat "$P/app.txt")" = live ] && [ ! -e "$D/alpha-app--live.zip" ] && break; sleep .1; done
[ "$(cat "$P/app.txt")" = live ]; [ ! -e "$D/alpha-app--live.zip" ]
printf 'OK: Downloads local importa somente projeto existente, valida, faz backup e remove ZIP no sucesso\n'
