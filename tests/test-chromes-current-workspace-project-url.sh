#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/chromes-current-workspace-test-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.config/google-chrome/Profile 7" "$TMP/home/.config/google-chrome/Profile 3" "$TMP/state/desktops"
cat > "$TMP/home/.config/google-chrome/Local State" <<'JSON'
{"profile":{"info_cache":{"Profile 7":{"name":"danielmaiax"},"Profile 3":{"name":"Sindicatto"}}}}
JSON
cat > "$TMP/projects" <<'PROJECTS'
bots/dev-automation
orgs/orbital/orbital-app
orgs/inst-app
PROJECTS
cat > "$TMP/services.csv" <<'SERVICES'
application;type;web_port;api_port;host;path
orbital-app;base;4001;8001;admin.localhost;/
site-inst;base;4003;8003;anpprev.localhost;/
site-inst;base;4003;8003;sinproprev.localhost;/
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
case "${1:-}" in info) printf '  Version: 11\n  State: ACTIVE\n' ;; esac
FAKE
chmod +x "$TMP/bin/"*
cat > "$TMP/state/desktops/extension.ready" <<'READY'
version=12
controller=1
floating-label=0
window-placement=1
READY
: > "$TMP/chrome.log"
(
  req="$TMP/state/desktops/chromes.request"
  for _ in $(seq 1 120); do
    if [[ -s "$req" ]]; then
      request="$(cat "$req")"; IFS=$'\t' read -r token _ <<< "$request"
      # Sem CHROMES_TARGET_WORKSPACE: o controlador informa que o workspace atual é o 4 (inst-app).
      printf '%s\tworkspace=4\tmonitor=0\tmaximize=1\n' "$token" > "$TMP/state/desktops/chromes.ready"
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
) & watcher=$!
out="$(HOME="$TMP/home" PATH="$TMP/bin:$PATH" XDG_SESSION_TYPE=wayland AUTO_CODE_STATE_DIR="$TMP/state" PROJECTS_FILE="$TMP/projects" SERVICES_FILE="$TMP/services.csv" CHROMES_TEST_LOG="$TMP/chrome.log" "$ROOT/scripts/chromes/ubuntu.sh")"
wait "$watcher"
grep -Fq -- '--profile-directory=Profile 7 --new-window https://chatgpt.com/' "$TMP/chrome.log"
grep -Fq -- '--profile-directory=Profile 3 --new-window https://anpprev.localhost/ https://sinproprev.localhost/' "$TMP/chrome.log"
grep -Fq 'Projeto: inst-app -> https://anpprev.localhost/ https://sinproprev.localhost/' <<< "$out"
grep -Fq 'Destino: workspace atual 4, monitor mais à esquerda, maximizado.' <<< "$out"
echo 'OK: chromes manual usa o workspace atual para resolver projeto/URLs, igual ao chromes-all.'
