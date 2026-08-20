#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d /tmp/devauto-zip-symlink-XXXXXX)"
trap 'rm -rf -- "$T" /tmp/devauto-symlink-escaped.txt' EXIT
M="$T/manager"; C="$T/Code"; H="$T/home"; D="$H/Downloads"; S="$T/state"; P="$C/orgs/alpha-app"
cp -a -- "$ROOT" "$M"
mkdir -p "$P" "$D" "$S"
printf 'old\n' > "$P/app.txt"
cat > "$M/config/auto-code-manager.projects" <<'CFG'
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
run(){ HOME="$H" DOWNLOADS_DIR="$D" CODE_ROOT="$C" AUTO_CODE_STATE_DIR="$S" AUTO_CODE_TUI=off "$M/scripts/auto-code-manager.sh" "$@"; }

mkdir -p "$T/pkg/server_backup/etc/nginx/sites-enabled"
ln -s /etc/nginx/sites-available/default "$T/pkg/server_backup/etc/nginx/sites-enabled/default"
printf 'backup\n' > "$T/pkg/backup.txt"
(cd "$T/pkg" && zip -qry "$D/alpha-app--backup-symlink.zip" .)
run --import-downloads-once >/dev/null
[ -L "$P/server_backup/etc/nginx/sites-enabled/default" ]
[ "$(readlink "$P/server_backup/etc/nginx/sites-enabled/default")" = '/etc/nginx/sites-available/default' ]
[ "$(cat "$P/backup.txt")" = backup ]
[ ! -e "$D/alpha-app--backup-symlink.zip" ]

python3 - "$D/alpha-app--symlink-traversal.zip" <<'PY'
import stat, sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    link = zipfile.ZipInfo('pivot')
    link.create_system = 3
    link.external_attr = (stat.S_IFLNK | 0o777) << 16
    z.writestr(link, '/tmp')
    z.writestr('pivot/devauto-symlink-escaped.txt', 'bad')
PY
if run --import-downloads-once >/dev/null 2>&1; then
  echo 'FALHOU: ZIP que atravessa symlink foi aceito' >&2
  exit 1
fi
[ -e "$D/alpha-app--symlink-traversal.zip" ]
[ ! -e /tmp/devauto-symlink-escaped.txt ]

printf 'OK: symlink legítimo é preservado e travessia através de symlink continua bloqueada\n'
