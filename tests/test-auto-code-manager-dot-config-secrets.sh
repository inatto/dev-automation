#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d /tmp/devauto-dot-config-secrets-XXXXXX)"
trap 'rm -rf -- "$T"' EXIT
M="$T/manager"; C="$T/Code"; H="$T/home"; D="$H/Downloads"; S="$T/state"; P="$C/orgs/alpha-app"
cp -a -- "$ROOT" "$M"
mkdir -p "$P/.config/tools" "$P/apps/api/.config" "$D" "$S"
cat > "$P/.config/tools/app.env" <<'ENV'
PUBLIC_URL=/old
API_TOKEN=real-dot-config-token
DATABASE_URL=postgresql://user:real-dot-config-password@localhost/db
ENV
cat > "$P/apps/api/.config/service.conf" <<'ENV'
SERVICE_ENABLED=true
SERVICE_PASSWORD=real-service-password
ENV
printf 'opaque-real-secret\n' > "$P/.config/tools/private.bin"
printf 'orgs/alpha-app\n' > "$M/config/auto-code-manager.projects"
cat > "$M/config/auto-code-manager.env" <<'ENV'
AUTO_CODE_MONITOR_MODE=inotify
BACKUP_EVERY=1
STABLE_WAIT=1
BEEP_MODE=none
BACKUP_BEEP_ENABLED=false
TASKBAR_STATUS_ENABLED=false
ENV
run(){ HOME="$H" DOWNLOADS_DIR="$D" CODE_ROOT="$C" DEV_MANAGER_PROJECTS_FILE="$M/config/auto-code-manager.projects" AUTO_CODE_STATE_DIR="$S" AUTO_CODE_TUI=off "$M/scripts/auto-code-manager.sh" "$@"; }

run --backup-once >/dev/null 2>&1
Z="$C/alpha-app.zip"
unzip -p "$Z" .config/tools/app.env | grep -Fxq 'API_TOKEN=********'
unzip -p "$Z" .config/tools/app.env | grep -Fxq 'DATABASE_URL=postgresql://user:********@localhost/db'
unzip -p "$Z" apps/api/.config/service.conf | grep -Fxq 'SERVICE_PASSWORD=********'
[ "$(unzip -p "$Z" .config/tools/private.bin)" = '********' ]
grep -Fxq 'API_TOKEN=real-dot-config-token' "$P/.config/tools/app.env"
grep -Fxq 'SERVICE_PASSWORD=real-service-password' "$P/apps/api/.config/service.conf"

PK="$T/pkg"; mkdir -p "$PK/.config/tools" "$PK/apps/api/.config"
cat > "$PK/.config/tools/app.env" <<'ENV'
PUBLIC_URL=/new
API_TOKEN=***
DATABASE_URL=postgresql://user:***@db.internal/newdb
NEW_FLAG=true
ENV
cat > "$PK/apps/api/.config/service.conf" <<'ENV'
SERVICE_ENABLED=false
SERVICE_PASSWORD=********
ENV
printf 'chat-must-not-overwrite\n' > "$PK/.config/tools/private.bin"
(cd "$PK" && zip -qr "$D/alpha-app--dot-config.zip" .)
run --import-downloads-once >/dev/null 2>&1

grep -Fxq 'PUBLIC_URL=/new' "$P/.config/tools/app.env"
grep -Fxq 'API_TOKEN=real-dot-config-token' "$P/.config/tools/app.env"
grep -Fxq 'DATABASE_URL=postgresql://user:real-dot-config-password@db.internal/newdb' "$P/.config/tools/app.env"
grep -Fxq 'NEW_FLAG=true' "$P/.config/tools/app.env"
grep -Fxq 'SERVICE_ENABLED=false' "$P/apps/api/.config/service.conf"
grep -Fxq 'SERVICE_PASSWORD=real-service-password' "$P/apps/api/.config/service.conf"
grep -Fxq 'opaque-real-secret' "$P/.config/tools/private.bin"
! grep -RIn --exclude-dir=.git -E 'chat-must-not-overwrite|API_TOKEN=\*+|SERVICE_PASSWORD=\*+' "$P" >/dev/null

echo 'OK: .config inteiro usa a mesma ida mascarada e volta com segredo local preservado'
