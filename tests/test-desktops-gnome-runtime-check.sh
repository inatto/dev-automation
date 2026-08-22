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
case "${1:-}" in
  info) printf '  Version: 4\n  State: ACTIVE\n'; exit 0 ;;
  enable) exit 0 ;;
esac
exit 0
FAKE
chmod +x "$TMP/bin/"*
set +e
out="$(PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_SESSION_TYPE=wayland DESKTOPS_PLATFORM=gnome PROJECTS_FILE="$TMP/projects" "$ROOT/scripts/desktops.sh" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]]
grep -Fq 'sessão Wayland ainda usa a versão anterior' <<<"$out"
grep -Fq 'falta apenas UM logout/login' <<<"$out"
echo 'OK: desktops prepara a atualização, sincroniza e pede um único novo login sem tratar a transição como erro.'
