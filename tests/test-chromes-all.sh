#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/chromes-all-test-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/projects" <<'PROJECTS'
bots/dev-automation
bots/dev-automation/apps/amazon-imap-bot
orgs/orbital/orbital-app
orgs/inst-app
infra/amazon-infra/apps/monitor-app
PROJECTS
cat > "$TMP/services.csv" <<'SERVICES'
application;type;web_port;api_port;host;path
orbital-app;base;4001;8001;admin.localhost;/
site-inst;base;4003;8003;anpprev.localhost;/
site-inst;base;4003;8003;sinproprev.localhost;/
amazon-infra-monitor;base;4005;8005;monitor.amazon-infra.localhost;/
SERVICES

cat > "$TMP/fake-chromes" <<'FAKE'
#!/usr/bin/env bash
{
  printf 'workspace=%s\n' "${CHROMES_TARGET_WORKSPACE:-}"
  printf 'projects=%s\n' "${PROJECTS_FILE:-}"
  printf 'services=%s\n' "${SERVICES_FILE:-}"
  printf 'local_urls=%s\n' "${CHROMES_LOCAL_URLS:-UNSET}"
  printf 'maximize=%s\n' "${CHROMES_MAXIMIZE:-UNSET}"
  printf 'files=%s\n' "${CHROMES_FILES_DIR:-UNSET}"
  printf '%s\n' '---'
} >> "$CHROMES_ALL_TEST_LOG"
FAKE
cat > "$TMP/fake-desktops" <<'FAKE'
#!/usr/bin/env bash
printf 'desktops:%s:%s\n' "${PROJECTS_FILE:-}" "${DESKTOPS_PLATFORM:-}" >> "$CHROMES_ALL_DESKTOPS_LOG"
FAKE
cat > "$TMP/bin/sleep" <<'FAKE'
#!/usr/bin/env bash
printf 'sleep=%s\n' "$1" >> "$CHROMES_ALL_SLEEP_LOG"
FAKE
chmod +x "$TMP/fake-chromes" "$TMP/fake-desktops" "$TMP/bin/sleep"
: > "$TMP/chromes.log"
: > "$TMP/desktops.log"
: > "$TMP/sleep.log"

PATH="$TMP/bin:$PATH" \
PROJECTS_FILE="$TMP/projects" \
SERVICES_FILE="$TMP/services.csv" \
CHROMES_COMMAND="$TMP/fake-chromes" \
DESKTOPS_COMMAND="$TMP/fake-desktops" \
CHROMES_ALL_TEST_LOG="$TMP/chromes.log" \
CHROMES_ALL_DESKTOPS_LOG="$TMP/desktops.log" \
CHROMES_ALL_SLEEP_LOG="$TMP/sleep.log" \
XDG_SESSION_TYPE=x11 \
  "$ROOT/scripts/chromes-all.sh" >/dev/null

[[ "$(grep -c '^workspace=' "$TMP/chromes.log")" -eq 4 ]]
grep -Fqx 'workspace=2' "$TMP/chromes.log"
grep -Fqx 'workspace=3' "$TMP/chromes.log"
grep -Fqx 'workspace=4' "$TMP/chromes.log"
grep -Fqx 'workspace=5' "$TMP/chromes.log"

# DRY: chromes-all só escolhe workspace; URL/maximização/Files pertencem ao chromes.
[[ "$(grep -c '^local_urls=UNSET$' "$TMP/chromes.log")" -eq 4 ]]
[[ "$(grep -c '^maximize=UNSET$' "$TMP/chromes.log")" -eq 4 ]]
[[ "$(grep -c '^files=UNSET$' "$TMP/chromes.log")" -eq 4 ]]

# O subprojeto bots/dev-automation/apps/... não consome desktop.
! grep -Fq 'amazon-imap-bot' "$TMP/chromes.log"

# Quatro desktops => três intervalos, sempre exatamente 1 segundo.
[[ "$(grep -c '^sleep=1$' "$TMP/sleep.log")" -eq 3 ]]
[[ "$(wc -l < "$TMP/sleep.log")" -eq 3 ]]

echo 'OK: chromes-all usa a mesma lista de desktops, ignora subprojetos e espera 1s entre projetos.' 
