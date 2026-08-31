#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP="$(mktemp -d /tmp/auto-code-subproject-roundtrip-XXXXXX)"
TEST_PROJECT="$TEMP/dev-automation"
CODE_ROOT="$TEMP/Code"
INBOX="$TEMP/inbox"
FAKE_BIN="$TEMP/fake-bin"
LOG="$TEMP/import.log"
PARENT="$CODE_ROOT/bots/dev-automation"
CHILD="$PARENT/apps/amazon-imap-bot"
trap 'rm -rf -- "$TEMP"' EXIT

cp -a -- "$ROOT" "$TEST_PROJECT"
mkdir -p \
  "$FAKE_BIN" \
  "$INBOX" \
  "$CHILD/config/local" \
  "$PARENT/apps/gpt-console" \
  "$PARENT/.config/amazon-imap-bot"
cat > "$FAKE_BIN/powershell.exe" <<'PS'
#!/usr/bin/env bash
exit 0
PS
chmod +x "$FAKE_BIN/powershell.exe"

printf 'parent-original\n' > "$PARENT/root.txt"
printf 'other-app-original\n' > "$PARENT/apps/gpt-console/ui.txt"
printf 'child-original\n' > "$CHILD/bot.py"
printf 'TOKEN=child-local-secret\n' > "$CHILD/config/local/.env"
cat > "$PARENT/.config/amazon-imap-bot/database.env" <<'ENV'
DB_HOST=127.0.0.1
DB_USER=mailbot
DB_PASSWORD=parent-local-db-secret
ENV

cat > "$TEST_PROJECT/config/projects/default.projects" <<'PROJECTS'
bots/dev-automation
bots/dev-automation/apps/amazon-imap-bot
PROJECTS
cat > "$TEST_PROJECT/config/auto-code-manager.ignore-zip" <<'IGNORE'
.git/
.venv/
venv/
node_modules/
IGNORE
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"
cat > "$TEST_PROJECT/config/auto-code-manager.env" <<'ENV'
STABLE_WAIT=1
BACKUP_EVERY=20
BEEP_MODE=none
TASKBAR_STATUS_ENABLED=false
ENV

MANAGER_ENV=(
  "PATH=$FAKE_BIN:$PATH"
  "CODE_ROOT=$CODE_ROOT"
  "DEV_MANAGER_PROJECTS_FILE=$TEST_PROJECT/config/projects/default.projects"
)

env "${MANAGER_ENV[@]}" "$TEST_PROJECT/scripts/auto-code-manager.sh" --backup-once >/dev/null

PARENT_ZIP="$CODE_ROOT/dev-automation.zip"
CHILD_ZIP="$CODE_ROOT/dev-automation-amazon-imap-bot.zip"
[ -s "$PARENT_ZIP" ]
[ -s "$CHILD_ZIP" ]

! unzip -Z1 "$PARENT_ZIP" | grep -q '^apps/amazon-imap-bot/'
! unzip -Z1 "$PARENT_ZIP" | grep -q '^.config/amazon-imap-bot/'
unzip -Z1 "$PARENT_ZIP" | grep -Fxq 'apps/gpt-console/ui.txt'
unzip -Z1 "$CHILD_ZIP" | grep -Fxq 'apps/amazon-imap-bot/bot.py'
unzip -Z1 "$CHILD_ZIP" | grep -Fxq '.config/amazon-imap-bot/database.env'
unzip -p "$CHILD_ZIP" .config/amazon-imap-bot/database.env | grep -Fxq 'DB_HOST=127.0.0.1'
unzip -p "$CHILD_ZIP" .config/amazon-imap-bot/database.env | grep -Fxq 'DB_PASSWORD=********'
if unzip -Z1 "$CHILD_ZIP" | grep -Ev '^(apps/|apps/amazon-imap-bot/|.config/|.config/amazon-imap-bot/)' | grep -q .; then
  printf 'FALHOU: ZIP filho contém caminho fora de apps/amazon-imap-bot e .config/amazon-imap-bot\n' >&2
  unzip -Z1 "$CHILD_ZIP" >&2
  exit 1
fi

PARENT_PACKAGE="$TEMP/parent-package"
mkdir -p \
  "$PARENT_PACKAGE/apps/amazon-imap-bot/config/local" \
  "$PARENT_PACKAGE/apps/gpt-console" \
  "$PARENT_PACKAGE/.config/amazon-imap-bot"
printf 'parent-imported\n' > "$PARENT_PACKAGE/root.txt"
printf 'other-app-imported\n' > "$PARENT_PACKAGE/apps/gpt-console/ui.txt"
printf 'child-overwrite-forbidden\n' > "$PARENT_PACKAGE/apps/amazon-imap-bot/bot.py"
printf 'TOKEN=child-overwrite-forbidden\n' > "$PARENT_PACKAGE/apps/amazon-imap-bot/config/local/.env"
cat > "$PARENT_PACKAGE/.config/amazon-imap-bot/database.env" <<'ENV'
DB_HOST=parent-overwrite-forbidden
DB_USER=mailbot
DB_PASSWORD=********
ENV
(
  cd "$PARENT_PACKAGE"
  zip -qr "$INBOX/dev-automation--parent-update.zip" .
)

env "${MANAGER_ENV[@]}" "$TEST_PROJECT/scripts/auto-code-manager.sh" \
  --import-one "$INBOX/dev-automation--parent-update.zip" > "$LOG"

grep -Fxq 'parent-imported' "$PARENT/root.txt"
grep -Fxq 'other-app-imported' "$PARENT/apps/gpt-console/ui.txt"
grep -Fxq 'child-original' "$CHILD/bot.py"
grep -Fxq 'TOKEN=child-local-secret' "$CHILD/config/local/.env"
grep -Fxq 'DB_HOST=127.0.0.1' "$PARENT/.config/amazon-imap-bot/database.env"
grep -Fxq 'DB_PASSWORD=parent-local-db-secret' "$PARENT/.config/amazon-imap-bot/database.env"
grep -Fq 'subprojeto(s) cadastrado(s) isolado(s) da importação do pai' "$LOG"

CHILD_PACKAGE="$TEMP/child-package"
mkdir -p "$CHILD_PACKAGE/apps/amazon-imap-bot" "$CHILD_PACKAGE/.config/amazon-imap-bot"
printf 'child-imported\n' > "$CHILD_PACKAGE/apps/amazon-imap-bot/bot.py"
printf 'parent-overwrite-forbidden\n' > "$CHILD_PACKAGE/root.txt"
cat > "$CHILD_PACKAGE/.config/amazon-imap-bot/database.env" <<'ENV'
DB_HOST=10.0.0.55
DB_USER=mailbot-v2
DB_PASSWORD=********
ENV
(
  cd "$CHILD_PACKAGE"
  zip -qr "$INBOX/dev-automation-amazon-imap-bot.zip" .
)

env "${MANAGER_ENV[@]}" "$TEST_PROJECT/scripts/auto-code-manager.sh" \
  --import-one "$INBOX/dev-automation-amazon-imap-bot.zip" >/dev/null

grep -Fxq 'child-imported' "$CHILD/bot.py"
grep -Fxq 'parent-imported' "$PARENT/root.txt"
grep -Fxq 'DB_HOST=10.0.0.55' "$PARENT/.config/amazon-imap-bot/database.env"
grep -Fxq 'DB_USER=mailbot-v2' "$PARENT/.config/amazon-imap-bot/database.env"
grep -Fxq 'DB_PASSWORD=parent-local-db-secret' "$PARENT/.config/amazon-imap-bot/database.env"
[ ! -e "$CHILD/.config/amazon-imap-bot/database.env" ]

printf 'OK: ZIP filho carrega apps/amazon-imap-bot + .config/amazon-imap-bot, mascara segredo e restaura a config na raiz do pai\n'
