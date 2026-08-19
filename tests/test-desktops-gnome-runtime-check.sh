#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/desktops-gnome-runtime-check-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
cat > "$TMP/projects" <<'PROJECTS'
bots/dev-automation
PROJECTS
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
# Simula enable aceito pelo CLI, mas extensão quebrada sem ui.ready.
exit 0
FAKE
chmod +x "$TMP/bin/"*
set +e
out="$(PATH="$TMP/bin:$PATH" HOME="$TMP/home" DESKTOPS_PLATFORM=gnome PROJECTS_FILE="$TMP/projects" "$ROOT/scripts/desktops.sh" 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]]
grep -Fq 'não confirmou o indicador único no canto inferior direito' <<<"$out"
echo 'OK: desktops falha explicitamente se o GNOME não confirmar a UI visual.'
