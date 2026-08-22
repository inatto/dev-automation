#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/files-all-test-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/projects" <<'PROJECTS'
bots/dev-automation
orgs/orbital/orbital-app
orgs/inst-app
PROJECTS
cat > "$TMP/fake-files" <<'FAKE'
#!/usr/bin/env bash
printf 'workspace=%s\n' "${FILES_TARGET_WORKSPACE:-}" >> "$FILES_ALL_TEST_LOG"
FAKE
cat > "$TMP/fake-desktops" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
cat > "$TMP/bin/sleep" <<'FAKE'
#!/usr/bin/env bash
printf 'sleep=%s\n' "$1" >> "$FILES_ALL_SLEEP_LOG"
FAKE
chmod +x "$TMP/fake-files" "$TMP/fake-desktops" "$TMP/bin/sleep"
: > "$TMP/files.log"
: > "$TMP/sleep.log"
PATH="$TMP/bin:$PATH" PROJECTS_FILE="$TMP/projects" FILES_COMMAND="$TMP/fake-files" DESKTOPS_COMMAND="$TMP/fake-desktops" FILES_ALL_TEST_LOG="$TMP/files.log" FILES_ALL_SLEEP_LOG="$TMP/sleep.log" XDG_SESSION_TYPE=x11 "$ROOT/scripts/files-all.sh" >/dev/null
[[ "$(cat "$TMP/files.log")" == $'workspace=2\nworkspace=3\nworkspace=4' ]]
[[ "$(cat "$TMP/sleep.log")" == $'sleep=2\nsleep=2' ]]
echo 'OK: files-all chama files em cada workspace e espera exatamente 2s entre desktops.'
