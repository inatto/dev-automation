#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/chromes-no-url-test-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.config/google-chrome/Default" "$TMP/home/.config/google-chrome/Profile 2" "$TMP/state/desktops"
cat > "$TMP/home/.config/google-chrome/Local State" <<'JSON'
{"profile":{"info_cache":{"Default":{"name":"danielmaiax"},"Profile 2":{"name":"Sindicatto"}}}}
JSON
printf 'bots/dev-automation\n' > "$TMP/projects"
printf 'application;type;web_port;api_port;host;path\n' > "$TMP/services.csv"
cat > "$TMP/bin/google-chrome-stable" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CHROMES_TEST_LOG"
FAKE
cat > "$TMP/bin/gnome-shell" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
cat > "$TMP/bin/gnome-extensions" <<'FAKE'
#!/usr/bin/env bash
printf '  Version: 11\n  State: ACTIVE\n'
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
  for _ in $(seq 1 100); do
    if [[ -s "$req" ]]; then
      request="$(cat "$req")"; IFS=$'\t' read -r token _ <<< "$request"
      printf '%s\tworkspace=2\tmonitor=0\tmaximize=1\n' "$token" > "$TMP/state/desktops/chromes.ready"
      for _ in $(seq 1 100); do
        if [[ "$(wc -l < "$TMP/chrome.log")" -ge 1 ]]; then
          printf '%s\tbrowsers=1\tnautilus=0\n' "$token" > "$TMP/state/desktops/chromes.result"
          exit 0
        fi
        sleep 0.05
      done
    fi
    sleep 0.05
  done
  exit 1
) & watcher=$!
out="$(HOME="$TMP/home" PATH="$TMP/bin:$PATH" XDG_SESSION_TYPE=wayland AUTO_CODE_STATE_DIR="$TMP/state" PROJECTS_FILE="$TMP/projects" SERVICES_FILE="$TMP/services.csv" CHROMES_TEST_LOG="$TMP/chrome.log" CHROMES_TARGET_WORKSPACE=2 "$ROOT/scripts/chromes/ubuntu.sh")"
wait "$watcher"
[[ "$(wc -l < "$TMP/chrome.log")" -eq 1 ]]
grep -Fq 'Chrome Sindicatto ignorado: dev-automation não possui URL local configurada.' <<< "$out"
echo 'OK: projeto sem URL abre somente Chrome Daniel/ChatGPT.'
