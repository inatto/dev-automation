#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/chromes-wayland-test-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.config/google-chrome/Default" "$TMP/home/.config/google-chrome/Profile 3" "$TMP/state/desktops"
printf 'bots/dev-automation\n' > "$TMP/projects"
cat > "$TMP/home/.config/google-chrome/Local State" <<'JSON'
{
  "profile": {
    "last_used": "Profile 3",
    "info_cache": {
      "Default": {"name": "Daniel"},
      "Profile 3": {"name": "Sindicatto"}
    }
  }
}
JSON

cat > "$TMP/bin/gsettings" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
cat > "$TMP/bin/gnome-shell" <<'FAKE'
#!/usr/bin/env bash
printf 'GNOME Shell 50.1\n'
FAKE
cat > "$TMP/bin/gnome-extensions" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  info)
    dir="${AUTO_CODE_STATE_DIR:-$HOME/.local/state/dev-automation}/desktops"
    if [[ -s "$dir/extension.ready" ]]; then
      printf '  Version: 11\n  State: ACTIVE\n'
    else
      printf '  Version: 11\n  State: INACTIVE\n'
    fi
    exit 0
    ;;
  enable)
    dir="${AUTO_CODE_STATE_DIR:-$HOME/.local/state/dev-automation}/desktops"
    mkdir -p "$dir"
    cat > "$dir/extension.ready" <<'READY'
version=13
controller=1
floating-label=0
window-placement=1
READY
    exit 0
    ;;
esac
exit 0
FAKE
cat > "$TMP/bin/google-chrome-stable" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CHROMES_TEST_LOG"
FAKE
chmod +x "$TMP/bin/"*
: > "$TMP/chrome.log"

(
  for _ in $(seq 1 120); do
    req="$TMP/state/desktops/chromes.request"
    if [[ -s "$req" ]]; then
      request="$(cat "$req")"
      IFS=$'\t' read -r token _ <<< "$request"
      printf '%s\tworkspace=7\tmonitor=0\tmaximize=1\n' "$token" > "$TMP/state/desktops/chromes.ready"
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
  CHROMES_TEST_LOG="$TMP/chrome.log" \
  CHROMES_LOCAL_URLS='https://admin.localhost/' \
    "$ROOT/scripts/chromes/ubuntu.sh"
)"
wait "$watcher"

grep -Fq 'Destino: workspace atual 7, monitor mais à esquerda, maximizado.' <<<"$out"
grep -Fq 'Chrome confirmado no workspace atual / monitor esquerdo / maximizado.' <<<"$out"
[[ "$(wc -l < "$TMP/chrome.log")" -eq 2 ]]
grep -Fq -- '--profile-directory=Default' "$TMP/chrome.log"
grep -Fq -- '--profile-directory=Profile 3' "$TMP/chrome.log"
echo 'OK: chromes usa o workspace atual e abre as janelas maximizadas no monitor esquerdo.'
grep -Fq 'workspace=' "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq 'maximize' "$ROOT/apps/desktops-gnome-extension/extension.js"
