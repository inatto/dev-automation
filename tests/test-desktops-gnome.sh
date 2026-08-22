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
  info)
    dir="${AUTO_CODE_STATE_DIR:-$HOME/.local/state/dev-automation}/desktops"
    if [[ -s "$dir/extension.ready" ]]; then
      printf '  Version: 10\n  State: ACTIVE\n'
    else
      printf '  Version: 10\n  State: INACTIVE\n'
    fi
    exit 0
    ;;
  enable)
    mkdir -p "$HOME/.local/state/dev-automation/desktops"
    cat > "$HOME/.local/state/dev-automation/desktops/extension.ready" <<'READY'
version=10
controller=1
floating-label=0
window-placement=1
READY
    exit 0
    ;;
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
! grep -q "dev-automation-workspace-corner" "$ROOT/apps/desktops-gnome-extension/extension.js"
! grep -q "getWorkAreaForMonitor" "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -q "floating-label=0" "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -q "window-placement=1" "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -q "_leftmostMonitor" "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -q "_rightmostMonitor" "$ROOT/apps/desktops-gnome-extension/extension.js"
! grep -q "PanelMenu.Button" "$ROOT/apps/desktops-gnome-extension/extension.js"
! grep -q "Main.panel.addToStatusArea" "$ROOT/apps/desktops-gnome-extension/extension.js"
! grep -q "Main.overview.connect" "$ROOT/apps/desktops-gnome-extension/extension.js"
! grep -q "workspace-overview" "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -q "close.request" "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -q "window.delete(timestamp)" "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -q "workspace.index() <= 0" "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq '"version": 10' "$TMP/home/.local/share/gnome-shell/extensions/workspace-name-osd@dev-automation/metadata.json"
echo 'OK: GNOME usa workspaces fixos nomeados, sem indicador flutuante, e fechamento preservando LAZER.'
