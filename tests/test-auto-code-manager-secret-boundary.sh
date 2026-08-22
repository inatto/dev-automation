#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d /tmp/devauto-secrets-XXXXXX)"
trap 'rm -rf -- "$T"' EXIT
M="$T/manager"; C="$T/Code"; H="$T/home"; D="$H/Downloads"; S="$T/state"; P="$C/orgs/alpha-app"
cp -a -- "$ROOT" "$M"
mkdir -p "$P/apps/api/config/local" "$P/apps/api/config/production" "$D" "$S"
printf 'SAFE\n' > "$P/app.txt"
cat > "$P/apps/api/config/local/app.env" <<'ENV'
PUBLIC_API_URL=/api-old
DB_PASSWORD=real-local-secret
DATABASE_URL=postgresql://user:real-url-secret@localhost/db
TOKEN=real-token
ENV
printf 'opaque-real-secret\n' > "$P/apps/api/config/local/private.bin"
cat > "$P/apps/api/config/production/app.env" <<'ENV'
PUBLIC_API_URL=/prod-old
PASSWORD="real-prod-secret"
ENV
printf 'orgs/alpha-app\n' > "$M/config/auto-code-manager.projects"
cat > "$M/config/auto-code-manager.env" <<'ENV'
AUTO_CODE_MONITOR_MODE=inotify
BACKUP_EVERY=1
STABLE_WAIT=1
BEEP_MODE=none
BACKUP_BEEP_ENABLED=false
TASKBAR_STATUS_ENABLED=false
ENV
run(){ HOME="$H" DOWNLOADS_DIR="$D" CODE_ROOT="$C" AUTO_CODE_STATE_DIR="$S" AUTO_CODE_TUI=off "$M/scripts/auto-code-manager.sh" "$@"; }

run --backup-once >/dev/null 2>&1
Z="$C/alpha-app.zip"
[ -s "$Z" ]
unzip -p "$Z" apps/api/config/local/app.env | grep -Fxq 'DB_PASSWORD=********'
unzip -p "$Z" apps/api/config/local/app.env | grep -Fxq 'DATABASE_URL=postgresql://user:********@localhost/db'
unzip -p "$Z" apps/api/config/local/app.env | grep -Fxq 'TOKEN=********'
unzip -p "$Z" apps/api/config/local/app.env | grep -Fxq 'PUBLIC_API_URL=/api-old'
[ "$(unzip -p "$Z" apps/api/config/local/private.bin)" = '********' ]
grep -Fxq 'DB_PASSWORD=real-local-secret' "$P/apps/api/config/local/app.env"
grep -Fxq 'opaque-real-secret' "$P/apps/api/config/local/private.bin"

PK="$T/pkg"; mkdir -p "$PK/apps/api/config/local" "$PK/apps/api/config/production"
printf 'UPDATED\n' > "$PK/app.txt"
cat > "$PK/apps/api/config/local/app.env" <<'ENV'
PUBLIC_API_URL=/api-new
DB_PASSWORD=chat-must-not-win
DATABASE_URL=postgresql://user:chat-must-not-win@db.internal/newdb
TOKEN=***
NEW_FLAG=true
ENV
printf 'chat-must-not-overwrite-opaque\n' > "$PK/apps/api/config/local/private.bin"
cat > "$PK/apps/api/config/production/app.env" <<'ENV'
PUBLIC_API_URL=/prod-new
PASSWORD="***"
ENV
(cd "$PK" && zip -qr "$D/alpha-app--secrets.zip" .)
run --import-downloads-once >/dev/null 2>&1

[ "$(cat "$P/app.txt")" = UPDATED ]
grep -Fxq 'PUBLIC_API_URL=/api-new' "$P/apps/api/config/local/app.env"
grep -Fxq 'DB_PASSWORD=real-local-secret' "$P/apps/api/config/local/app.env"
grep -Fxq 'DATABASE_URL=postgresql://user:real-url-secret@db.internal/newdb' "$P/apps/api/config/local/app.env"
grep -Fxq 'TOKEN=real-token' "$P/apps/api/config/local/app.env"
grep -Fxq 'NEW_FLAG=true' "$P/apps/api/config/local/app.env"
grep -Fxq 'opaque-real-secret' "$P/apps/api/config/local/private.bin"
grep -Fxq 'PUBLIC_API_URL=/prod-new' "$P/apps/api/config/production/app.env"
grep -Fxq 'PASSWORD="real-prod-secret"' "$P/apps/api/config/production/app.env"
[ ! -e "$D/alpha-app--secrets.zip" ]
! find "$P" -name '*.external' -print -quit | grep -q .
! grep -RIn --exclude-dir=.git -E 'chat-must-not-win|\*\*\*' "$P" >/dev/null

echo 'OK: ida mascara segredos; volta preserva segredo local e aplica somente mudanças seguras'
