#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SOURCE_ROOT="$PROJECT_ROOT"
TEMP_ROOT="$(mktemp -d /tmp/auto-code-parent-backup-test-XXXXXX)"
TEST_PROJECT="$TEMP_ROOT/dev-automation"
CODE_ROOT="$TEMP_ROOT/Code"
MANAGER="$TEST_PROJECT/scripts/auto-code-manager.sh"
LOG_FILE="$TEMP_ROOT/backup.log"
FAKE_BIN="$TEMP_ROOT/fake-bin"
SOUND_LOG="$TEMP_ROOT/sound.log"
MODULES=(orbital-app orbital-assets orbital-fin orbital-mail orbital-reports)

cleanup() {
  rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT

cp -a -- "$SOURCE_ROOT" "$TEST_PROJECT"
mkdir -p "$CODE_ROOT/orgs/inst-app" "$FAKE_BIN"

cat > "$FAKE_BIN/powershell.exe" <<'PS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_PS_LOG:?}"
exit 0
PS
chmod +x "$FAKE_BIN/powershell.exe"

for module in "${MODULES[@]}"; do
  mkdir -p "$CODE_ROOT/orgs/orbital/$module"
  printf '%s\n' "$module" > "$CODE_ROOT/orgs/orbital/$module/module.txt"
done

mkdir -p \
  "$CODE_ROOT/orgs/orbital/orbital-app/apps/api/config/local" \
  "$CODE_ROOT/orgs/orbital/orbital-app/apps/api/config/remote" \
  "$CODE_ROOT/orgs/orbital/orbital-app/apps/api/config/production" \
  "$CODE_ROOT/orgs/orbital/orbital-app/apps/api/config/development" \
  "$CODE_ROOT/orgs/orbital/orbital-app/config"

cat > "$CODE_ROOT/orgs/orbital/orbital-app/apps/api/config/local/.env" <<'ENV'
DB_HOST=127.0.0.1
DB_PORT=1521
DB_USER=orbital
DB_PASSWORD=local-real-password
TENANT_CODE=anpprev
ENV

cat > "$CODE_ROOT/orgs/orbital/orbital-app/apps/api/config/remote/.env.remote" <<'ENV'
ORACLE_DSN=remote_high
ORACLE_PASSWORD="remote-real-password"
DATABASE_URL=postgresql://orbital:url-real-password@db.example.com:5432/orbital
ENV

cat > "$CODE_ROOT/orgs/orbital/orbital-app/apps/api/config/production/settings.env" <<'ENV'
export DATABASE_PASSWORD='production-real-password'
SMTP_HOST=smtp.example.com
ENV

cat > "$CODE_ROOT/orgs/orbital/orbital-app/apps/api/config/development/.env" <<'ENV'
DB_PASSWORD=development-real-password
ENV

cat > "$CODE_ROOT/orgs/orbital/orbital-app/apps/api/config/local/auth.env" <<'ENV'
SSO_CLIENT_ID=email-app
SSO_CLIENT_SECRET=local-client-secret
ENV

cat > "$CODE_ROOT/orgs/orbital/orbital-app/config/mailer_config.ini" <<'ENV'
[mailer]
host=smtp.example.com
token=mailer-real-token
password=mailer-real-password
ENV

cat > "$CODE_ROOT/orgs/orbital/orbital-app/config/services.env" <<'ENV'
ORACLE_CLIENT_SECRET=oracle-client-secret
ORACLE_WALLET_PASSWORD=wallet-real-password
SMTP2GO_API_KEY=smtp2go-real-api-key
ENV

printf 'compartilhado\n' > "$CODE_ROOT/orgs/orbital/README-parent.txt"
printf 'inst\n' > "$CODE_ROOT/orgs/inst-app/inst.txt"

cat > "$TEST_PROJECT/config/auto-code-manager.projects" <<'PROJECTS'
orgs/orbital/orbital-app
orgs/orbital/orbital-assets
orgs/orbital/orbital-fin
orgs/orbital/orbital-mail
orgs/orbital/orbital-reports
orgs/inst-app
PROJECTS

: > "$TEST_PROJECT/config/auto-code-manager.ignore-zip"
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"
: > "$SOUND_LOG"

PATH="$FAKE_BIN:$PATH" \
FAKE_PS_LOG="$SOUND_LOG" \
CODE_ROOT="$CODE_ROOT" \
  "$MANAGER" --backup-once >"$LOG_FILE"

sound_count="$(grep -Fc 'System.Media.SoundPlayer' "$SOUND_LOG" || true)"
if [ "$sound_count" -ne 0 ]; then
  printf 'FALHOU: a rodada de backup não deveria tocar som, mas tocou %s vez(es).\n' "$sound_count" >&2
  cat "$SOUND_LOG" >&2 || true
  exit 1
fi

EXPECTED_ARCHIVES=(
  orbital-app.zip
  orbital-assets.zip
  orbital-fin.zip
  orbital-mail.zip
  orbital-reports.zip
  inst-app.zip
  orbital.zip
  Code.zip
)

for archive in "${EXPECTED_ARCHIVES[@]}"; do
  if [ ! -s "$CODE_ROOT/$archive" ]; then
    printf 'FALHOU: ZIP ausente: %s\n' "$CODE_ROOT/$archive" >&2
    cat "$LOG_FILE" >&2 || true
    exit 1
  fi
  unzip -tq "$CODE_ROOT/$archive" >/dev/null
  printf 'OK ZIP: %s\n' "$archive"
done

local_env="$(unzip -p "$CODE_ROOT/orbital-app.zip" apps/api/config/local/.env)"
remote_env="$(unzip -p "$CODE_ROOT/orbital-app.zip" apps/api/config/remote/.env.remote)"
production_env="$(unzip -p "$CODE_ROOT/orbital-app.zip" apps/api/config/production/settings.env)"
development_env="$(unzip -p "$CODE_ROOT/orbital-app.zip" apps/api/config/development/.env)"
auth_env="$(unzip -p "$CODE_ROOT/orbital-app.zip" apps/api/config/local/auth.env)"
mailer_ini="$(unzip -p "$CODE_ROOT/orbital-app.zip" config/mailer_config.ini)"
services_env="$(unzip -p "$CODE_ROOT/orbital-app.zip" config/services.env)"

printf '%s\n' "$local_env" | grep -Fxq 'DB_HOST=127.0.0.1'
printf '%s\n' "$local_env" | grep -Fxq 'DB_USER=orbital'
printf '%s\n' "$local_env" | grep -Fxq 'DB_PASSWORD=********'
printf '%s\n' "$local_env" | grep -Fxq 'TENANT_CODE=anpprev'
printf '%s\n' "$remote_env" | grep -Fxq 'ORACLE_PASSWORD="********"'
printf '%s\n' "$remote_env" | grep -Fxq 'DATABASE_URL=postgresql://orbital:********@db.example.com:5432/orbital'
printf '%s\n' "$production_env" | grep -Fxq "export DATABASE_PASSWORD='********'"
printf '%s\n' "$production_env" | grep -Fxq 'SMTP_HOST=smtp.example.com'
printf '%s\n' "$development_env" | grep -Fxq 'DB_PASSWORD=********'
printf '%s\n' "$auth_env" | grep -Fxq 'SSO_CLIENT_ID=email-app'
printf '%s\n' "$auth_env" | grep -Fxq 'SSO_CLIENT_SECRET=********'
printf '%s\n' "$mailer_ini" | grep -Fxq 'host=smtp.example.com'
printf '%s\n' "$mailer_ini" | grep -Fxq 'token=********'
printf '%s\n' "$mailer_ini" | grep -Fxq 'password=********'
printf '%s\n' "$services_env" | grep -Fxq 'ORACLE_CLIENT_SECRET=********'
printf '%s\n' "$services_env" | grep -Fxq 'ORACLE_WALLET_PASSWORD=********'
printf '%s\n' "$services_env" | grep -Fxq 'SMTP2GO_API_KEY=********'

grep -Fxq 'DB_PASSWORD=local-real-password' "$CODE_ROOT/orgs/orbital/orbital-app/apps/api/config/local/.env"
grep -Fxq 'ORACLE_PASSWORD="remote-real-password"' "$CODE_ROOT/orgs/orbital/orbital-app/apps/api/config/remote/.env.remote"
grep -Fxq "export DATABASE_PASSWORD='production-real-password'" "$CODE_ROOT/orgs/orbital/orbital-app/apps/api/config/production/settings.env"
grep -Fxq 'SSO_CLIENT_SECRET=local-client-secret' "$CODE_ROOT/orgs/orbital/orbital-app/apps/api/config/local/auth.env"
grep -Fxq 'token=mailer-real-token' "$CODE_ROOT/orgs/orbital/orbital-app/config/mailer_config.ini"
grep -Fxq 'SMTP2GO_API_KEY=smtp2go-real-api-key' "$CODE_ROOT/orgs/orbital/orbital-app/config/services.env"

if unzip -p "$CODE_ROOT/orbital-app.zip" | grep -Fq 'real-password'; then
  printf 'FALHOU: uma senha real vazou no ZIP do orbital-app.\n' >&2
  exit 1
fi

printf 'OK: configs .env/.ini em qualquer pasta config preservados com apenas os segredos sanitizados\n'
printf 'OK: arquivos originais permaneceram intactos\n'

# O ZIP pai contém exclusivamente os cinco ZIPs filhos ativos.
for module in "${MODULES[@]}"; do
  unzip -Z1 "$CODE_ROOT/orbital.zip" | grep -Fxq "$module.zip"

  if unzip -Z1 "$CODE_ROOT/orbital.zip" | grep -q "^$module/"; then
    printf 'FALHOU: orbital.zip duplicou a pasta %s/\n' "$module" >&2
    exit 1
  fi

done
if unzip -Z1 "$CODE_ROOT/orbital.zip" | grep -Fxq 'README-parent.txt'; then
  printf 'FALHOU: orbital.zip incluiu arquivo solto da pasta pai.\n' >&2
  exit 1
fi

if [ "$(unzip -Z1 "$CODE_ROOT/orbital.zip" | wc -l)" -ne "${#MODULES[@]}" ]; then
  printf 'FALHOU: orbital.zip deve conter somente os ZIPs filhos ativos.\n' >&2
  unzip -Z1 "$CODE_ROOT/orbital.zip" >&2
  exit 1
fi

for archive in "${EXPECTED_ARCHIVES[@]}"; do
  [ "$archive" = 'Code.zip' ] && continue
  unzip -Z1 "$CODE_ROOT/Code.zip" | grep -Fxq "$archive"
done

identified="$(CODE_ROOT="$CODE_ROOT" "$MANAGER" --identify-zip orbital.zip)"
[ "$identified" = 'orgs/orbital' ] || {
  printf 'FALHOU: orbital.zip identificado como %s\n' "$identified" >&2
  exit 1
}

printf 'OK: orbital.zip contém somente os cinco ZIPs filhos ativos e está dentro de Code.zip\n'
printf 'OK: backup concluído sem aviso sonoro\n'
