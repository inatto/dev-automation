#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/terminals-wayland-test-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state/desktops"
printf 'bots/dev-automation\n' > "$TMP/projects"

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
      printf '  Version: 8\n  State: ACTIVE\n'
    else
      printf '  Version: 8\n  State: INACTIVE\n'
    fi
    exit 0
    ;;
  enable)
    dir="${AUTO_CODE_STATE_DIR:-$HOME/.local/state/dev-automation}/desktops"
    mkdir -p "$dir"
    cat > "$dir/extension.ready" <<'READY'
version=8
controller=1
floating-label=0
window-placement=1
READY
    exit 0
    ;;
esac
exit 0
FAKE
cat > "$TMP/bin/ptyxis" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TERMINALS_TEST_LOG"
FAKE
chmod +x "$TMP/bin/"*
: > "$TMP/terminal.log"

(
  for _ in $(seq 1 120); do
    req="$TMP/state/desktops/terminals.request"
    if [[ -s "$req" ]]; then
      token="$(cat "$req")"
      printf '%s\tcount=3\tfirst_workspace=2\tmonitor=2\n' "$token" > "$TMP/state/desktops/terminals.ready"
      for _ in $(seq 1 120); do
        if [[ "$(wc -l < "$TMP/terminal.log")" -ge 3 ]]; then
          printf '%s\tplaced=3\texpected=3\tcomplete=1\n' "$token" > "$TMP/state/desktops/terminals.result"
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
  TERMINALS_TEST_LOG="$TMP/terminal.log" \
    "$ROOT/scripts/terminals.sh"
)"
wait "$watcher"

[[ "$(wc -l < "$TMP/terminal.log")" -eq 3 ]]
grep -Fq -- '--new-window' "$TMP/terminal.log"
grep -Fq -- '--working-directory=' "$TMP/terminal.log"
grep -Fq '3/3 terminais distribuídos nos workspaces de projeto, no monitor direito, sem maximizar e sem trocar seu workspace atual.' <<<"$out"
grep -Fq 'index + 1' "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq 'window.unmaximize(Meta.MaximizeFlags.BOTH)' "$ROOT/apps/desktops-gnome-extension/extension.js"
echo 'OK: terminals ignora LAZER, cria somente nos projetos e força janela não maximizada à direita.'
