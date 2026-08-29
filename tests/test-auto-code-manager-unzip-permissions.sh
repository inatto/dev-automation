#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d /tmp/devauto-unzip-mode-XXXXXX)"
cleanup(){ rm -rf -- "$T"; }
trap cleanup EXIT

M="$T/manager"
C="$T/Code"
H="$T/home"
D="$H/Downloads"
S="$T/state"
P="$C/orgs/alpha-app"
PKG="$T/package"

cp -a -- "$ROOT" "$M"
mkdir -p "$P/deploy/local" "$D" "$S" "$PKG/deploy/local"

printf 'old\n' > "$P/deploy/local/setup.sh"
chmod 755 "$P/deploy/local/setup.sh"

cat > "$M/config/projects/default.projects" <<'PROJECTS'
orgs/alpha-app
PROJECTS
printf '.git/\n.venv/\nvenv/\nnode_modules/\n' > "$M/config/auto-code-manager.ignore-zip"
: > "$M/config/auto-code-manager.ignore-unzip"
: > "$M/config/auto-code-manager.folder-sql-zip"
cat > "$M/config/auto-code-manager.env" <<'ENV'
AUTO_CODE_MONITOR_MODE=inotify
BACKUP_EVERY=1
STABLE_WAIT=1
BEEP_REPEATS=1
BEEP_GAP_MS=1
BEEP_MODE=none
BACKUP_BEEP_ENABLED=false
TASKBAR_STATUS_ENABLED=false
ENV

# Caso correto: saiu executável e voltou executável.
printf 'new\n' > "$PKG/deploy/local/setup.sh"
chmod 755 "$PKG/deploy/local/setup.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$PKG/deploy/local/new-task.sh"
chmod 755 "$PKG/deploy/local/new-task.sh"
(
  cd "$PKG"
  zip -qr "$D/alpha-app--permissions-ok.zip" .
)

HOME="$H" DOWNLOADS_DIR="$D" CODE_ROOT="$C" AUTO_CODE_STATE_DIR="$S" AUTO_CODE_TUI=off \
  "$M/scripts/auto-code-manager.sh" --import-downloads-once >/dev/null

[ "$(cat "$P/deploy/local/setup.sh")" = new ]
[ "$(stat -c '%a' "$P/deploy/local/setup.sh")" = 755 ]
[ "$(stat -c '%a' "$P/deploy/local/new-task.sh")" = 755 ]
[ ! -e "$D/alpha-app--permissions-ok.zip" ]

# O ZIP é a fonte de verdade: se ele trouxer 0644, a importação deve aplicar 0644.
rm -rf -- "$PKG"
mkdir -p "$PKG/deploy/local"
printf 'mode-from-zip\n' > "$PKG/deploy/local/setup.sh"
chmod 644 "$PKG/deploy/local/setup.sh"
(
  cd "$PKG"
  zip -qr "$D/alpha-app--permissions-644.zip" .
)

HOME="$H" DOWNLOADS_DIR="$D" CODE_ROOT="$C" AUTO_CODE_STATE_DIR="$S" AUTO_CODE_TUI=off \
  "$M/scripts/auto-code-manager.sh" --import-downloads-once >/dev/null

[ "$(cat "$P/deploy/local/setup.sh")" = mode-from-zip ]
[ "$(stat -c '%a' "$P/deploy/local/setup.sh")" = 644 ]
[ ! -e "$D/alpha-app--permissions-644.zip" ]

printf 'OK: chmod armazenado no ZIP é reaplicado fielmente na importação\n'
