#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d /tmp/auto-code-protected-config-test-XXXXXX)"
TEST_PROJECT="$TEMP_ROOT/dev-automation"
CODE_ROOT="$TEMP_ROOT/Code"
DOWNLOADS_DIR="$TEMP_ROOT/Downloads"
STATE_DIR="$TEMP_ROOT/state"
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
  "$DOWNLOADS_DIR" "$FAKE_BIN"

cat > "$FAKE_BIN/powershell.exe" <<'PS'
#!/usr/bin/env bash
exit 0
PS
chmod +x "$FAKE_BIN/powershell.exe"

cat > "$DEST/apps/api/config/local/database.env" <<'ENV'
HOST=127.0.0.1
PORT=8100
DB_PASSWORD=senha-local-real
ENV
cat > "$DEST/apps/api/config/remote/database.env" <<'ENV'
HOST=127.0.0.1
PORT=8100
DB_PASSWORD=senha-remota-real
ENV
cat > "$DEST/apps/api/config/production/database.env" <<'ENV'
HOST=127.0.0.1
PORT=8100
DB_PASSWORD=senha-producao-real
ENV
printf 'desenvolvimento-antigo\n' > "$DEST/apps/api/config/development/database.env"
printf 'codigo-antigo\n' > "$DEST/app.py"

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

# Gera o backup sanitizado e, junto, a referência exata enviada para análise.
PATH="$FAKE_BIN:$PATH" \
CODE_ROOT="$CODE_ROOT" \
DOWNLOADS_DIR="$DOWNLOADS_DIR" \
AUTO_CODE_STATE_DIR="$STATE_DIR" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" --backup-once >/dev/null 2>&1

BASELINE="$STATE_DIR/protected-config-baselines/sample-app"
grep -Fxq 'DB_PASSWORD=********' "$BASELINE/apps/api/config/local/database.env"
grep -Fxq 'PORT=8100' "$BASELINE/apps/api/config/remote/database.env"

# Simula o ZIP devolvido pelo ChatGPT: todos os envs podem voltar.
mkdir -p \
  "$PACKAGE/apps/api/config/local" \
  "$PACKAGE/apps/api/config/remote" \
  "$PACKAGE/apps/api/config/production" \
  "$PACKAGE/apps/api/config/development"

# Igual ao enviado: deve ser descartado (sem .external).
cp "$BASELINE/apps/api/config/local/database.env" "$PACKAGE/apps/api/config/local/database.env"
cp "$BASELINE/apps/api/config/production/database.env" "$PACKAGE/apps/api/config/production/database.env"

# Alterado: deve aparecer somente como .external.
cat > "$PACKAGE/apps/api/config/remote/database.env" <<'ENV'
HOST=127.0.0.1
PORT=8110
DB_PASSWORD=********
ENV

# Novo: deve aparecer somente como .external.
cat > "$PACKAGE/apps/api/config/local/new.env" <<'ENV'
NEW_URL=http://127.0.0.1:9999
NEW_PASSWORD=********
ENV

printf 'desenvolvimento-novo\n' > "$PACKAGE/apps/api/config/development/database.env"
printf 'codigo-novo\n' > "$PACKAGE/app.py"

(
  cd "$PACKAGE"
  zip -qr "$DOWNLOADS_DIR/sample-app.zip" .
)

PATH="$FAKE_BIN:$PATH" \
CODE_ROOT="$CODE_ROOT" \
DOWNLOADS_DIR="$DOWNLOADS_DIR" \
AUTO_CODE_STATE_DIR="$STATE_DIR" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" --import-downloads-once > "$LOG_FILE" 2>&1

# Os envs reais permanecem intactos, inclusive os que tiveram versão externa alterada.
grep -Fxq 'DB_PASSWORD=senha-local-real' "$DEST/apps/api/config/local/database.env"
grep -Fxq 'PORT=8100' "$DEST/apps/api/config/remote/database.env"
grep -Fxq 'DB_PASSWORD=senha-remota-real' "$DEST/apps/api/config/remote/database.env"
grep -Fxq 'DB_PASSWORD=senha-producao-real' "$DEST/apps/api/config/production/database.env"

# Env igual ao enviado não gera lixo para revisar.
[ ! -e "$DEST/apps/api/config/local/database.env.external" ]
[ ! -e "$DEST/apps/api/config/production/database.env.external" ]

# Somente env alterado/novo vira .external.
grep -Fxq 'PORT=8110' "$DEST/apps/api/config/remote/database.env.external"
grep -Fxq 'DB_PASSWORD=********' "$DEST/apps/api/config/remote/database.env.external"
grep -Fxq 'NEW_URL=http://127.0.0.1:9999' "$DEST/apps/api/config/local/new.env.external"
[ ! -e "$DEST/apps/api/config/local/new.env" ]

# Outras pastas config e código continuam atualizando normalmente.
grep -Fxq 'desenvolvimento-novo' "$DEST/apps/api/config/development/database.env"
grep -Fxq 'codigo-novo' "$DEST/app.py"

[ ! -e "$DOWNLOADS_DIR/sample-app.zip" ]
grep -Fq 'ENV protegidos: 2 alterado(s)/novo(s), 2 sem mudança.' "$LOG_FILE"
grep -Fq 'ENV EXTERNAL: apps/api/config/remote/database.env -> apps/api/config/remote/database.env.external' "$LOG_FILE"
grep -Fq 'ENV EXTERNAL: apps/api/config/local/new.env -> apps/api/config/local/new.env.external' "$LOG_FILE"

printf 'OK: env igual é descartado; alterado/novo vira .external; env real permanece intacto\n'
