#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/desktops-close-gnome-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state/desktops"
cat > "$TMP/projects" <<'EOF'
bots/dev-automation
EOF
cat > "$TMP/bin/gsettings" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP/bin/gnome-shell" <<'EOF'
#!/usr/bin/env bash
printf 'GNOME Shell 50.1\n'
EOF
cat > "$TMP/bin/gnome-extensions" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "enable" ]]; then
  mkdir -p "${AUTO_CODE_STATE_DIR:-$HOME/.local/state/dev-automation}/desktops"
  cat > "${AUTO_CODE_STATE_DIR:-$HOME/.local/state/dev-automation}/desktops/ui.ready" <<'READY'
version=4
corner=1
READY
fi
exit 0
EOF
chmod +x "$TMP/bin/"*
(
  for _ in $(seq 1 100); do
    req="$TMP/state/desktops/close.request"
    if [[ -s "$req" ]]; then
      token="$(cat "$req")"
      printf 'solicitadas=7 ignoradas=1\n' > "$TMP/state/desktops/close.result"
      printf '%s\n' "$token" > "$TMP/state/desktops/close.ready"
      exit 0
    fi
    sleep 0.05
  done
  exit 1
) &
watcher=$!
out="$(PATH="$TMP/bin:$PATH" HOME="$TMP/home" AUTO_CODE_STATE_DIR="$TMP/state" DESKTOPS_PLATFORM=gnome PROJECTS_FILE="$TMP/projects" "$ROOT/scripts/desktops.sh" --close)"
wait "$watcher"
grep -Fq 'LAZER preservado' <<<"$out"
grep -Fq 'solicitadas=7' <<<"$out"
echo 'OK: desktops --close fecha workspaces gerenciados por pedido GNOME e preserva LAZER.'
