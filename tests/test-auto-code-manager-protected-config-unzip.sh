#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d /tmp/auto-code-protected-config-test-XXXXXX)"
TEST_PROJECT="$TEMP_ROOT/dev-automation"
CODE_ROOT="$TEMP_ROOT/Code"
DOWNLOADS_DIR="$TEMP_ROOT/Downloads"
LOG_FILE="$TEMP_ROOT/import.log"
FAKE_BIN="$TEMP_ROOT/fake-bin"
DEST="$CODE_ROOT/orgs/sample-app"
PACKAGE="$TEMP_ROOT/package"

cleanup() { rm -rf -- "$TEMP_ROOT"; }
trap cleanup EXIT

cp -a -- "$PROJECT_ROOT" "$TEST_PROJECT"
mkdir -p \
  "$DEST/apps/api/config/local" \
  "$DEST/apps/api/config/remote" \
  "$DEST/apps/api/config/production" \
  "$DEST/apps/api/config/development" \
  "$DOWNLOADS_DIR" "$FAKE_BIN" \
  "$PACKAGE/apps/api/config/local" \
  "$PACKAGE/apps/api/config/remote" \
  "$PACKAGE/apps/api/config/production" \
  "$PACKAGE/apps/api/config/development"

cat > "$FAKE_BIN/powershell.exe" <<'PS'
#!/usr/bin/env bash
exit 0
PS
chmod +x "$FAKE_BIN/powershell.exe"

printf 'senha-local-real\n' > "$DEST/apps/api/config/local/database.env"
printf 'senha-remota-real\n' > "$DEST/apps/api/config/remote/database.env"
printf 'senha-producao-real\n' > "$DEST/apps/api/config/production/database.env"
printf 'desenvolvimento-antigo\n' > "$DEST/apps/api/config/development/database.env"
printf 'codigo-antigo\n' > "$DEST/app.py"

printf '********\n' > "$PACKAGE/apps/api/config/local/database.env"
printf 'novo-arquivo-protegido\n' > "$PACKAGE/apps/api/config/local/new.env"
printf '********\n' > "$PACKAGE/apps/api/config/remote/database.env"
printf '********\n' > "$PACKAGE/apps/api/config/production/database.env"
printf 'desenvolvimento-novo\n' > "$PACKAGE/apps/api/config/development/database.env"
printf 'codigo-novo\n' > "$PACKAGE/app.py"

(
  cd "$PACKAGE"
  zip -qr "$DOWNLOADS_DIR/sample-app.zip" .
)

cat > "$TEST_PROJECT/config/auto-code-manager.projects" <<'PROJECTS'
orgs/sample-app
PROJECTS
: > "$TEST_PROJECT/config/auto-code-manager.ignore-zip"
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"
cat > "$TEST_PROJECT/config/auto-code-manager.env" <<'ENV'
STABLE_WAIT=1
INTERVAL=1
ZONE_EVERY=1
BACKUP_EVERY=60
BEEP_REPEATS=1
BEEP_GAP_MS=1
BEEP_MODE=none
BEEP_VOLUME=0
BACKUP_BEEP_ENABLED=false
ENV

PATH="$FAKE_BIN:$PATH" \
CODE_ROOT="$CODE_ROOT" \
DOWNLOADS_DIR="$DOWNLOADS_DIR" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" --import-downloads-once > "$LOG_FILE" 2>&1

# As três pastas protegidas permanecem exatamente como estavam.
grep -Fxq 'senha-local-real' "$DEST/apps/api/config/local/database.env"
grep -Fxq 'senha-remota-real' "$DEST/apps/api/config/remote/database.env"
grep -Fxq 'senha-producao-real' "$DEST/apps/api/config/production/database.env"
[ ! -e "$DEST/apps/api/config/local/new.env" ]

# Outras pastas config e o código continuam sendo atualizados normalmente.
grep -Fxq 'desenvolvimento-novo' "$DEST/apps/api/config/development/database.env"
grep -Fxq 'codigo-novo' "$DEST/app.py"

[ ! -e "$DOWNLOADS_DIR/sample-app.zip" ]
grep -Fq 'Protegendo no unzip: */config/local/**, */config/remote/** e */config/production/**' "$LOG_FILE"

printf 'OK: unzip ignora somente config/local, config/remote e config/production\n'
