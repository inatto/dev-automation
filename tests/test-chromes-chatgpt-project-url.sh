#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/chromes-chatgpt-project-url-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.config/google-chrome/Default" "$TMP/state"
cat > "$TMP/home/.config/google-chrome/Local State" <<'JSON'
{"profile":{"info_cache":{"Default":{"name":"danielmaiax"}}}}
JSON
cat > "$TMP/projects" <<'PROJECTS'
orgs/orbital/orbital-fin
PROJECTS
printf 'application;type;web_port;api_port;host;path\n' > "$TMP/services.csv"
cat > "$TMP/chatgpt-projects.urls" <<'URLS'
orbital-fin | https://chatgpt.com/g/g-p-test-orbital-fin/project
URLS
cat > "$TMP/bin/google-chrome-stable" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CHROMES_TEST_LOG"
FAKE
chmod +x "$TMP/bin/google-chrome-stable"
: > "$TMP/chrome.log"

HOME="$TMP/home" \
PATH="$TMP/bin:$PATH" \
XDG_SESSION_TYPE=x11 \
AUTO_CODE_STATE_DIR="$TMP/state" \
PROJECTS_FILE="$TMP/projects" \
SERVICES_FILE="$TMP/services.csv" \
CHATGPT_PROJECTS_FILE="$TMP/chatgpt-projects.urls" \
CHROMES_TEST_LOG="$TMP/chrome.log" \
CHROMES_TARGET_WORKSPACE=2 \
CHROMES_SKIP_SECOND=1 \
  "$ROOT/scripts/chromes/ubuntu.sh" >/dev/null
for _ in $(seq 1 50); do [[ -s "$TMP/chrome.log" ]] && break; sleep 0.02; done

grep -Fxq -- '--no-first-run --profile-directory=Default --new-window https://chatgpt.com/g/g-p-test-orbital-fin/project' "$TMP/chrome.log"

: > "$TMP/chrome.log"
printf '# sem mapeamento\n' > "$TMP/chatgpt-projects.urls"
HOME="$TMP/home" \
PATH="$TMP/bin:$PATH" \
XDG_SESSION_TYPE=x11 \
AUTO_CODE_STATE_DIR="$TMP/state" \
PROJECTS_FILE="$TMP/projects" \
SERVICES_FILE="$TMP/services.csv" \
CHATGPT_PROJECTS_FILE="$TMP/chatgpt-projects.urls" \
CHROMES_TEST_LOG="$TMP/chrome.log" \
CHROMES_TARGET_WORKSPACE=2 \
CHROMES_SKIP_SECOND=1 \
  "$ROOT/scripts/chromes/ubuntu.sh" >/dev/null
for _ in $(seq 1 50); do [[ -s "$TMP/chrome.log" ]] && break; sleep 0.02; done

grep -Fxq -- '--no-first-run --profile-directory=Default --new-window https://chatgpt.com/' "$TMP/chrome.log"
echo 'OK: Chrome Daniel abre o Project ChatGPT do projeto e mantém fallback genérico.'
