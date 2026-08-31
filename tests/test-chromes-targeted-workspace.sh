#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/chromes-targeted-test-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.config/google-chrome/Profile 7" "$TMP/home/.config/google-chrome/Profile 3" "$TMP/state/desktops"
cat > "$TMP/home/.config/google-chrome/Local State" <<'JSON'
{
  "profile": {
    "last_used": "Profile 7",
    "info_cache": {
      "Profile 7": {"name": "danielmaiax", "gaia_name": "Daniel Maia", "user_name": "danielmaiax@example.test"},
      "Profile 3": {"name": "Sindicatto", "gaia_name": "Sindicatto", "user_name": "admin@sindicatto.test"}
    }
  }
}
JSON
cat > "$TMP/projects" <<'PROJECTS'
bots/dev-automation
orgs/orbital/orbital-app
orgs/inst-app
PROJECTS
cat > "$TMP/services.csv" <<'SERVICES'
application;type;web_port;api_port;host;path;tenants
orbital-app;base;4001;8001;admin.localhost;/;anpprev,sinproprev,asaclub
site-inst;base;4003;8003;anpprev.localhost;/;
site-inst;base;4003;8003;sinproprev.localhost;/;
SERVICES
cat > "$TMP/bin/google-chrome-stable" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CHROMES_TEST_LOG"
FAKE
cat > "$TMP/bin/gnome-shell" <<'FAKE'
#!/usr/bin/env bash
printf 'GNOME Shell 50.1\n'
FAKE
cat > "$TMP/bin/gnome-extensions" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  info) printf '  Version: 11\n  State: ACTIVE\n' ;;
esac
FAKE
chmod +x "$TMP/bin/"*
cat > "$TMP/state/desktops/extension.ready" <<'READY'
version=15
controller=1
floating-label=0
window-placement=1
terminal-direct=1
terminal-placement-verified=1
READY
: > "$TMP/chrome.log"

(
  req="$TMP/state/desktops/chromes.request"
  for _ in $(seq 1 120); do
    if [[ -s "$req" ]]; then
      request="$(cat "$req")"
      printf '%s\n' "$request" > "$TMP/request.log"
      IFS=$'\t' read -r token _ <<< "$request"
      printf '%s\tworkspace=3\tmonitor=0\tmaximize=1\n' "$token" > "$TMP/state/desktops/chromes.ready"
      for _ in $(seq 1 160); do
        if [[ "$(wc -l < "$TMP/chrome.log")" -ge 2 ]]; then
          printf '%s\tbrowsers=2\tnautilus=0\n' "$token" > "$TMP/state/desktops/chromes.result"
          exit 0
        fi
        sleep 0.05
      done
      exit 2
    fi
    sleep 0.05
  done
  exit 1
) &
watcher=$!

out="$(
  HOME="$TMP/home" \
  PATH="$TMP/bin:$PATH" \
  XDG_SESSION_TYPE=wayland \
  XDG_CURRENT_DESKTOP=GNOME \
  AUTO_CODE_STATE_DIR="$TMP/state" \
  PROJECTS_FILE="$TMP/projects" \
  SERVICES_FILE="$TMP/services.csv" \
  CHROMES_TEST_LOG="$TMP/chrome.log" \
  CHROMES_TARGET_WORKSPACE=3 \
    "$ROOT/scripts/chromes/ubuntu.sh"
)"
wait "$watcher"

grep -Fq $'action=default\tworkspace=3\tmaximize=1' "$TMP/request.log"
grep -Fq -- '--profile-directory=Profile 7 --new-window https://chatgpt.com/' "$TMP/chrome.log"
grep -Fq -- '--profile-directory=Profile 3 --new-window https://anpprev.admin.localhost/ https://sinproprev.admin.localhost/ https://asaclub.admin.localhost/' "$TMP/chrome.log"
grep -Fq 'Destino: workspace 3, monitor mais à esquerda, maximizado.' <<< "$out"
grep -Fq 'Projeto: orbital-app -> https://anpprev.admin.localhost/ https://sinproprev.admin.localhost/ https://asaclub.admin.localhost/' <<< "$out"
grep -Fq 'Chrome confirmado no workspace 3 / monitor esquerdo / maximizado.' <<< "$out"

# O controlador deve ativar o workspace alvo ANTES de liberar o Chrome.
chrome_prepare_block="$(sed -n '/_prepareChromes(token, fields = {}) {/,/_prepareTerminals(token, action, fields = {}) {/p' "$ROOT/apps/desktops-gnome-extension/extension.js")"
grep -Fq 'workspace.activate(global.get_current_time())' <<< "$chrome_prepare_block"
grep -Fq 'const activeWorkspace = global.workspace_manager.get_active_workspace_index();' <<< "$chrome_prepare_block"
! grep -qi 'nautilus\|files' "$TMP/chrome.log"
echo 'OK: chromes expande tenants do services.csv em abas do projeto Orbital e mantém posicionamento.'
