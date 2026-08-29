#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d /tmp/devauto-symlink-portability-XXXXXX)"
trap 'rm -rf -- "$T"' EXIT
M="$T/manager"; C="$T/Code"; H="$T/home"; D="$H/Downloads"; S="$T/state"; P="$C/orgs/alpha-app"
cp -a -- "$ROOT" "$M"
mkdir -p "$P/real" "$P/machine" "$D" "$S"
printf 'target-local\n' > "$P/real/local.txt"
printf 'machine-local\n' > "$P/machine/value.txt"
ln -s real "$P/link-filetree"
ln -s /etc/nginx/sites-available/default "$P/nginx-default"
ln -s ../machine "$P/linked-dir"
cat > "$M/config/projects/default.projects" <<'EOF_PROJECTS'
orgs/alpha-app
EOF_PROJECTS
cat > "$M/config/auto-code-manager.ignore-zip" <<'EOF_IGNORE'
.git/
.venv/
venv/
node_modules/
EOF_IGNORE
: > "$M/config/auto-code-manager.ignore-unzip"
: > "$M/config/auto-code-manager.folder-sql-zip"
cat > "$M/config/auto-code-manager.env" <<'EOF_ENV'
AUTO_CODE_MONITOR_MODE=inotify
BACKUP_EVERY=1
STABLE_WAIT=1
BEEP_REPEATS=1
BEEP_GAP_MS=1
BEEP_MODE=none
BACKUP_BEEP_ENABLED=false
TASKBAR_STATUS_ENABLED=false
EOF_ENV
run(){ HOME="$H" DOWNLOADS_DIR="$D" CODE_ROOT="$C" AUTO_CODE_STATE_DIR="$S" AUTO_CODE_TUI=off "$M/scripts/auto-code-manager.sh" "$@"; }

run --backup-once >/dev/null
Z="$C/alpha-app.zip"
unzip -tq "$Z" >/dev/null
if unzip -Z1 "$Z" | grep -Eq '(^|/)(link-filetree|nginx-default|linked-dir)/?$'; then
  echo 'FALHOU: symlink entrou no ZIP de backup' >&2
  unzip -Z1 "$Z" >&2
  exit 1
fi
[ -L "$P/link-filetree" ] && [ -L "$P/nginx-default" ] && [ -L "$P/linked-dir" ]

python3 - "$D/alpha-app--incoming.zip" <<'PY'
import stat, sys, zipfile
p=sys.argv[1]
with zipfile.ZipFile(p,'w') as z:
    z.writestr('normal.txt','novo\n')
    zi=zipfile.ZipInfo('nginx-default')
    zi.create_system=3
    zi.external_attr=(stat.S_IFLNK | 0o777) << 16
    z.writestr(zi,'/tmp/evil-target')
    z.writestr('linked-dir/value.txt','NAO-SUBSTITUIR\n')
PY
run --import-downloads-once >/dev/null
[ "$(cat "$P/normal.txt")" = novo ]
[ -L "$P/nginx-default" ]
[ "$(readlink "$P/nginx-default")" = /etc/nginx/sites-available/default ]
[ -L "$P/linked-dir" ]
[ "$(readlink "$P/linked-dir")" = ../machine ]
[ "$(cat "$P/machine/value.txt")" = machine-local ]
[ ! -e "$D/alpha-app--incoming.zip" ]

echo 'OK: symlinks não entram no ZIP, são ignorados no unzip e links locais ficam intocados'
