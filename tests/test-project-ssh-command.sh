#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

HOME_DIR="$TMP/home"
CODE_ROOT="$TMP/Code"
TARGET_DIR="$HOME_DIR/.local/bin"
PROJECTS_FILE="$TMP/projects"
APP="$CODE_ROOT/orgs/orbital/orbital-mail"
INFRA="$CODE_ROOT/infra/amazon-infra"
FAKE_BIN="$TMP/bin"
SSH_LOG="$TMP/ssh.log"

mkdir -p "$HOME_DIR" "$TARGET_DIR" "$APP/deploy/remote" \
  "$INFRA/ec2/52.67.135.170/domains" "$INFRA/ec2/52.67.135.170/core" \
  "$INFRA/lightsail/44.219.174.82/domains" "$FAKE_BIN"
: > "$HOME_DIR/.bashrc"
: > "$APP/deploy/remote/setup.sh"
: > "$INFRA/ec2/52.67.135.170/core/inatto01-sp.pem"
printf 'orgs/orbital/orbital-mail\n' > "$PROJECTS_FILE"

cat > "$INFRA/ec2/52.67.135.170/domains/admin.sindicatto.com.conf" <<CONF
REMOTE_USER="ubuntu"
REMOTE_HOST="52.67.135.170"
SSH_KEY="$INFRA/ec2/52.67.135.170/core/inatto01-sp.pem"
SITE_NAME="admin.sindicatto.com"
APP_NAME="orbital-app"
REMOTE_APP_DIR="/home/ubuntu/apps/orgs/orbital/orbital-app"
WEB_PROXY_LOCATIONS=(
  "/orbital-mail/|127.0.0.1|4106"
)
CONF

cat > "$INFRA/lightsail/44.219.174.82/domains/orbital.anpprev.org.conf" <<CONF
REMOTE_USER="ubuntu"
REMOTE_HOST="44.219.174.82"
SSH_KEY="$HOME_DIR/amazon.ssh"
SITE_NAME="orbital.anpprev.org"
APP_NAME="orbital-app"
REMOTE_APP_DIR="/home/ubuntu/apps/orbital/orbital-app"
WEB_PROXY_LOCATIONS=(
  "/orbital-mail/|127.0.0.1|4106"
)
CONF

cat > "$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
printf '200 0.123'
SH
chmod +x "$FAKE_BIN/curl"

cat > "$FAKE_BIN/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SSH_LOG:?}"
if [[ " $* " == *" BatchMode=yes "* ]]; then
  printf 'host=prod-ec2\nuptime=up 3 days\nload=0.10 0.20 0.30\ndisk_root=5G/20G (25%%)\n'
fi
exit 0
SH
chmod +x "$FAKE_BIN/ssh"

HOME="$HOME_DIR" TARGET_DIR="$TARGET_DIR" CODE_ROOT="$CODE_ROOT" PROJECTS_FILE="$PROJECTS_FILE" \
  "$ROOT/deploy/local/install-project-commands.sh" > "$TMP/install.log"

[[ -x "$TARGET_DIR/remote-orbital-mail" ]]
[[ -x "$TARGET_DIR/ssh-orbital-mail" ]]
grep -Fq 'criado: ssh-orbital-mail -> SSH remoto de orgs/orbital/orbital-mail' "$TMP/install.log"

SSH_LOG="$SSH_LOG" PATH="$FAKE_BIN:$PATH" HOME="$HOME_DIR" DEV_AUTOMATION_SKIP_CLEAR=1 \
  "$TARGET_DIR/ssh-orbital-mail" > "$TMP/run.log" 2> "$TMP/run.err"

grep -Fq 'servidor: ubuntu@52.67.135.170' "$TMP/run.log"
! grep -Fq '44.219.174.82' "$TMP/run.log"
grep -Fq 'site OK: HTTP 200 em 0.123s | https://admin.sindicatto.com/orbital-mail/' "$TMP/run.log"
grep -Fq 'SSH OK: ubuntu@52.67.135.170' "$TMP/run.log"
grep -Fq 'pasta remota do projeto: /home/ubuntu/apps/orgs/orbital/orbital-mail (inferido do padrão /apps/<projeto>)' "$TMP/run.log"
grep -Fq 'abrindo sessão SSH interativa em: /home/ubuntu/apps/orgs/orbital/orbital-mail' "$TMP/run.log"
[[ "$(wc -l < "$SSH_LOG")" -eq 2 ]]
grep -Fq 'BatchMode=yes ubuntu@52.67.135.170' "$SSH_LOG"
grep -Fq 'ubuntu@52.67.135.170' "$SSH_LOG"
grep -Fq '/home/ubuntu/apps/orgs/orbital/orbital-mail' "$SSH_LOG"


# Também funciona fora do amazon-infra, lendo .env.remote do próprio projeto.
DIRECT="$TMP/direct-app"
mkdir -p "$DIRECT/deploy/remote" "$HOME_DIR/direct"
: > "$HOME_DIR/direct.pem"
cat > "$DIRECT/deploy/remote/.env.remote" <<'CONF'
REMOTE_HOST="ec2-user@203.0.113.7"
SSH_KEY="${HOME}/direct.pem"
SITE_URL="https://sample.example/" # comentário permitido
CONF

: > "$SSH_LOG"
SSH_LOG="$SSH_LOG" PATH="$FAKE_BIN:$PATH" HOME="$HOME_DIR" DEV_AUTOMATION_SKIP_CLEAR=1 \
  "$ROOT/scripts/project-ssh.sh" ssh-direct-app "$DIRECT" orgs/direct-app "$CODE_ROOT" > "$TMP/direct.log" 2> "$TMP/direct.err"

grep -Fq 'servidor: ec2-user@203.0.113.7' "$TMP/direct.log"
grep -Fq 'site OK: HTTP 200 em 0.123s | https://sample.example/' "$TMP/direct.log"
[[ "$(wc -l < "$SSH_LOG")" -eq 2 ]]

echo 'OK: ssh-<projeto> detecta o EC2 atual, testa site/SSH e abre a sessão interativa'
