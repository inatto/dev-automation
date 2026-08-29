#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/desktops-controller-idempotent-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
TARGET="$TMP/home/.local/share/gnome-shell/extensions/workspace-name-osd@dev-automation"
mkdir -p "$TMP/bin" "$TMP/home/.local/state/dev-automation/desktops" "$TARGET"
printf 'bots/dev-automation\n' > "$TMP/projects"
cp -f -- "$ROOT/apps/desktops-gnome-extension/extension.js" "$TARGET/extension.js"
cp -f -- "$ROOT/apps/desktops-gnome-extension/stylesheet.css" "$TARGET/stylesheet.css"
cat > "$TARGET/metadata.json" <<'JSON'
{
  "uuid": "workspace-name-osd@dev-automation",
  "name": "Dev Automation Workspace Controller",
  "description": "Controla workspaces e posicionamento explícito de janelas sem criar indicador visual duplicado.",
  "shell-version": ["50"],
  "version": 15
}
JSON
cat > "$TMP/home/.local/state/dev-automation/desktops/extension.ready" <<'READY'
version=15
controller=1
floating-label=0
window-placement=1
terminal-direct=1
terminal-placement-verified=1
READY
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
  info) printf '  Version: 11\n  State: ACTIVE\n'; exit 0 ;;
  enable|disable) printf '%s\n' "$1" >> "$EXT_CALLS"; exit 0 ;;
esac
exit 0
FAKE
chmod +x "$TMP/bin/"*
: > "$TMP/ext.calls"
for _ in 1 2 3; do
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" XDG_SESSION_TYPE=wayland \
    DESKTOPS_PLATFORM=gnome PROJECTS_FILE="$TMP/projects" EXT_CALLS="$TMP/ext.calls" \
    "$ROOT/scripts/desktops.sh" >/dev/null
done
[[ ! -s "$TMP/ext.calls" ]]
grep -Fqx 'version=15' "$TMP/home/.local/state/dev-automation/desktops/extension.ready"
echo 'OK: controlador GNOME é idempotente; execuções repetidas não fazem enable/disable nem apagam o marker.'
