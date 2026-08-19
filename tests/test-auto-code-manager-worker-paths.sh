#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/devauto-worker-paths-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT

TEST_HOME="$TMP/home"
TEST_PROJECT="$TMP/dev-automation"
CODE_ROOT="$TMP/Code"
WORKER_TO_DIR="$TEST_HOME/worker/to"
WORKER_FROM_DIR="$TEST_HOME/worker/from"
DOWNLOADS_DIR="$TEST_HOME/Downloads"
FAKE_BIN="$TMP/fake-bin"

cp -a -- "$ROOT" "$TEST_PROJECT"
mkdir -p "$TEST_HOME" "$CODE_ROOT/orgs/sample-app" "$DOWNLOADS_DIR" "$FAKE_BIN"
printf 'original\n' > "$CODE_ROOT/orgs/sample-app/value.txt"
printf 'orgs/sample-app\n' > "$TEST_PROJECT/config/auto-code-manager.projects"
cat > "$TEST_PROJECT/config/auto-code-manager.ignore-zip" <<'IGNORE'
.git/
.venv/
venv/
node_modules/
IGNORE
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"
cat > "$TEST_PROJECT/config/auto-code-manager.env" <<'ENV'
STABLE_WAIT=1
INTERVAL=1
ZONE_EVERY=1
BACKUP_EVERY=1
BEEP_REPEATS=1
BEEP_GAP_MS=1
BEEP_MODE=none
BEEP_VOLUME=0
BACKUP_BEEP_ENABLED=false
ENV
cat > "$FAKE_BIN/powershell.exe" <<'PS'
#!/usr/bin/env bash
exit 0
PS
chmod +x "$FAKE_BIN/powershell.exe"

# 1) Sem override: backup deve ir para $HOME/worker/to, nunca para Code.
HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" CODE_ROOT="$CODE_ROOT" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" --backup-once >"$TMP/backup.log" 2>&1
[ -s "$WORKER_TO_DIR/sample-app.zip" ]
[ ! -e "$CODE_ROOT/sample-app.zip" ]
unzip -tq "$WORKER_TO_DIR/sample-app.zip" >/dev/null

# 2) ZIP em Downloads não entra mais na fila.
PKG1="$TMP/pkg-downloads"
mkdir -p "$PKG1"
printf 'NAO IMPORTAR\n' > "$PKG1/value.txt"
(cd "$PKG1" && zip -q "$DOWNLOADS_DIR/sample-app.zip" value.txt)
HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" CODE_ROOT="$CODE_ROOT" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" --import-worker-from-once >"$TMP/from-empty.log" 2>&1
[ -e "$DOWNLOADS_DIR/sample-app.zip" ]
grep -Fxq 'original' "$CODE_ROOT/orgs/sample-app/value.txt"

# 3) ZIP em $HOME/worker/from é importado e movido para backup com o MESMO nome.
mkdir -p "$WORKER_FROM_DIR"
PKG2="$TMP/pkg-from"
mkdir -p "$PKG2"
printf 'IMPORTADO DO FROM\n' > "$PKG2/value.txt"
(cd "$PKG2" && zip -q "$WORKER_FROM_DIR/sample-app.zip" value.txt)
HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" CODE_ROOT="$CODE_ROOT" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" --import-worker-from-once >"$TMP/from.log" 2>&1
grep -Fxq 'IMPORTADO DO FROM' "$CODE_ROOT/orgs/sample-app/value.txt"
[ ! -e "$WORKER_FROM_DIR/sample-app.zip" ]
[ -f "$WORKER_FROM_DIR/backup/sample-app.zip" ]
grep -Fq "Verificando worker/from: $WORKER_FROM_DIR" "$TMP/from.log"

echo 'OK: backup -> ~/worker/to; import <- ~/worker/from; Downloads ignorado'
