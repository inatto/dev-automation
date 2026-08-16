#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/desktops-gnome-test-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
cat > "$TMP/projects" <<'PROJECTS'
bots/dev-automation
orgs/orbital/orbital-app
PROJECTS
cat > "$TMP/bin/gsettings" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GSETTINGS_LOG"
FAKE
cat > "$TMP/bin/gnome-shell" <<'FAKE'
#!/usr/bin/env bash
printf 'GNOME Shell 50.1\n'
FAKE
cat > "$TMP/bin/gnome-extensions" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  info) exit 0 ;;
  enable) exit 0 ;;
esac
exit 0
FAKE
chmod +x "$TMP/bin/"*
export GSETTINGS_LOG="$TMP/gsettings.log"
PATH="$TMP/bin:$PATH" HOME="$TMP/home" DESKTOPS_PLATFORM=gnome PROJECTS_FILE="$TMP/projects" "$ROOT/scripts/desktops.sh" > "$TMP/out"
grep -Fq 'org.gnome.mutter dynamic-workspaces false' "$GSETTINGS_LOG"
grep -Fq 'org.gnome.desktop.wm.preferences num-workspaces 5' "$GSETTINGS_LOG"
grep -Fq "workspace-names ['LAZER', 'dev-automation', 'orbital-app', 'lrdp1', 'lrdp2']" "$GSETTINGS_LOG"
test -f "$TMP/home/.local/share/gnome-shell/extensions/workspace-name-osd@dev-automation/extension.js"
grep -q "active-workspace-changed" "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -q "close.request" "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -q "window.delete(timestamp)" "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -q "workspace.index() <= 0" "$ROOT/apps/desktops-gnome-extension/extension.js"
echo 'OK: GNOME usa workspaces fixos nomeados, lrdp1/lrdp2 no final, OSD e fechamento dos workspaces gerenciados preservando LAZER.'
