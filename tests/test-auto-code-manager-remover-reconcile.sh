#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP="$(mktemp -d /tmp/auto-code-remover-reconcile-XXXXXX)"
TEST_PROJECT="$TEMP/manager"
CODE_ROOT="$TEMP/Code"
DOWNLOADS="$TEMP/Downloads"
STATE="$TEMP/state"
FAKE_BIN="$TEMP/fake-bin"
DEST="$CODE_ROOT/orgs/sample-app"
trap 'rm -rf -- "$TEMP"' EXIT

cp -a -- "$ROOT" "$TEST_PROJECT"
mkdir -p "$DEST/old-dir" "$DOWNLOADS" "$FAKE_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/powershell.exe"
chmod +x "$FAKE_BIN/powershell.exe"
cat > "$TEST_PROJECT/config/projects/default.projects" <<'CFG'
orgs/sample-app
CFG
cat > "$TEST_PROJECT/config/auto-code-manager.ignore-zip" <<'CFG'
.git/
.venv/
venv/
node_modules/
CFG
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"
cat > "$TEST_PROJECT/config/auto-code-manager.env" <<'CFG'
STABLE_WAIT=1
BACKUP_EVERY=1
BEEP_MODE=none
BACKUP_BEEP_ENABLED=false
TASKBAR_STATUS_ENABLED=false
CFG

printf 'old\n' > "$DEST/code.txt"
printf 'obsolete\n' > "$DEST/obsolete.txt"
printf 'nested\n' > "$DEST/old-dir/a.txt"

pkg="$TEMP/pkg-ok"
mkdir -p "$pkg"
printf 'new\n' > "$pkg/code.txt"
: > "$pkg/obsolete.txt.remover"
: > "$pkg/old-dir.remover"
(cd "$pkg" && zip -qr "$DOWNLOADS/sample-app.zip" .)

PATH="$FAKE_BIN:$PATH" CODE_ROOT="$CODE_ROOT" WORKER_FROM_DIR="$DOWNLOADS" AUTO_CODE_STATE_DIR="$STATE" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" --import-one "$DOWNLOADS/sample-app.zip" >/dev/null

grep -Fxq new "$DEST/code.txt"
[ ! -e "$DEST/obsolete.txt" ]
[ ! -e "$DEST/old-dir" ]
[ ! -e "$DEST/obsolete.txt.remover" ]
[ ! -e "$DEST/old-dir.remover" ]
[ ! -e "$DOWNLOADS/sample-app.zip" ]

# O marcador é transitório e jamais volta para o ZIP de backup.
PATH="$FAKE_BIN:$PATH" CODE_ROOT="$CODE_ROOT" WORKER_FROM_DIR="$DOWNLOADS" AUTO_CODE_STATE_DIR="$STATE" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" --backup-once >/dev/null
! unzip -Z1 "$CODE_ROOT/sample-app.zip" | grep -q '\.remover$'

# Arquivo e marcador para o mesmo alvo: recusa antes do rsync e conserva o ZIP.
pkg="$TEMP/pkg-conflict"
mkdir -p "$pkg"
printf 'conflict-new\n' > "$pkg/code.txt"
: > "$pkg/code.txt.remover"
(cd "$pkg" && zip -qr "$DOWNLOADS/sample-app.zip" .)
if PATH="$FAKE_BIN:$PATH" CODE_ROOT="$CODE_ROOT" WORKER_FROM_DIR="$DOWNLOADS" AUTO_CODE_STATE_DIR="$STATE" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" --import-one "$DOWNLOADS/sample-app.zip" >/dev/null 2>&1; then
  echo 'FALHOU: arquivo + .remover para o mesmo alvo foi aceito' >&2
  exit 1
fi
grep -Fxq new "$DEST/code.txt"
[ -e "$DOWNLOADS/sample-app.zip" ]
rm -f -- "$DOWNLOADS/sample-app.zip"

# Nunca atravessa symlink de diretório para remover algo fora do projeto.
mkdir -p "$TEMP/outside"
printf 'safe\n' > "$TEMP/outside/victim.txt"
ln -s "$TEMP/outside" "$DEST/link"
pkg="$TEMP/pkg-symlink"
mkdir -p "$pkg/link"
: > "$pkg/link/victim.txt.remover"
(cd "$pkg" && zip -qr "$DOWNLOADS/sample-app.zip" .)
if PATH="$FAKE_BIN:$PATH" CODE_ROOT="$CODE_ROOT" WORKER_FROM_DIR="$DOWNLOADS" AUTO_CODE_STATE_DIR="$STATE" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" --import-one "$DOWNLOADS/sample-app.zip" >/dev/null 2>&1; then
  echo 'FALHOU: .remover atravessando symlink foi aceito' >&2
  exit 1
fi
grep -Fxq safe "$TEMP/outside/victim.txt"
[ -e "$DOWNLOADS/sample-app.zip" ]

printf 'OK: .remover é validado, aplicado após confirmação, não atravessa symlink e nunca volta ao backup\n'
