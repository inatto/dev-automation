#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d /tmp/devauto-new-secret-unzip-XXXXXX)"
trap 'rm -rf -- "$T"' EXIT

M="$T/manager"
C="$T/Code"
D="$T/Downloads"
S="$T/state"
H="$T/home"
P="$C/orgs/alpha-app"
PF="$T/projects"
PK="$T/package"
LOG="$T/import.log"

cp -a -- "$ROOT" "$M"
mkdir -p "$P/apps/api/config/production" "$D" "$S" "$H" "$PK/apps/api/config/production"
printf 'OLD\n' > "$P/app.txt"
cat > "$P/apps/api/config/production/services.env" <<'ENV'
DATABASE_ENABLED=false
DATABASE_USER=
DATABASE_DSN=localhost:1521/FREEPDB1
ENV

printf 'orgs/alpha-app\n' > "$PF"
cat > "$M/config/auto-code-manager.env" <<'ENV'
AUTO_CODE_MONITOR_MODE=inotify
STABLE_WAIT=1
BACKUP_EVERY=60
BEEP_MODE=none
BACKUP_BEEP_ENABLED=false
TASKBAR_STATUS_ENABLED=false
ENV
: > "$M/config/auto-code-manager.ignore-unzip"
cat > "$M/config/auto-code-manager.ignore-zip" <<'ENV'
.git/
.venv/
venv/
node_modules/
ENV

printf 'UPDATED\n' > "$PK/app.txt"
cat > "$PK/apps/api/config/production/services.env" <<'ENV'
DATABASE_ENABLED=false
DATABASE_USER=
DATABASE_PASSWORD=
DATABASE_DSN=localhost:1521/FREEPDB1
BOOTSTRAP_TOKEN=package-bootstrap-token
ENV
(cd "$PK" && zip -qr "$D/alpha-app--bootstrap.zip" .)

HOME="$H" TERM=xterm DOWNLOADS_DIR="$D" CODE_ROOT="$C" \
DEV_MANAGER_PROJECTS_FILE="$PF" AUTO_CODE_STATE_DIR="$S" AUTO_CODE_TUI=off \
  "$M/scripts/auto-code-manager.sh" --import-downloads-once > "$LOG" 2>&1

[ "$(cat "$P/app.txt")" = UPDATED ]
grep -Fxq 'DATABASE_PASSWORD=' "$P/apps/api/config/production/services.env"
grep -Fxq 'BOOTSTRAP_TOKEN=package-bootstrap-token' "$P/apps/api/config/production/services.env"
[ ! -e "$D/alpha-app--bootstrap.zip" ]
grep -Fq 'AVISO CONFIG PROTEGIDO:' "$LOG"
grep -Fq 'DATABASE_PASSWORD: chave sensível nova sem correspondente local; mantendo valor recebido' "$LOG"
grep -Fq 'BOOTSTRAP_TOKEN: chave sensível nova sem correspondente local; mantendo valor recebido' "$LOG"
grep -Fq 'IMPORTAÇÃO CONCLUÍDA' "$LOG"

echo 'OK: chave sensível nova sem valor local alerta, não bloqueia o unzip e o ZIP é removido após confirmação'
