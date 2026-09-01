#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/terminals-stale-controller-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
TARGET="$TMP/home/.local/share/gnome-shell/extensions/workspace-name-osd@dev-automation"
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state/desktops" "$TMP/code/a" "$TARGET"
printf 'a\n' > "$TMP/projects"
printf 'old controller without direct protocol\n' > "$TARGET/extension.js"
printf 'old style\n' > "$TARGET/stylesheet.css"
printf '{}\n' > "$TARGET/metadata.json"
cat > "$TMP/state/desktops/extension.ready" <<'READY'
version=13
controller=1
floating-label=0
window-placement=1
READY

cat > "$TMP/bin/gnome-shell" <<'FAKE'
#!/usr/bin/env bash
printf 'GNOME Shell 50.1\n'
FAKE
cat > "$TMP/bin/gsettings" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
cat > "$TMP/bin/gnome-extensions" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  info) printf '  Version: 14\n  State: ACTIVE\n' ;;
  enable|disable) exit 9 ;;
esac
FAKE
cat > "$TMP/bin/ptyxis" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TERMINALS_TEST_LOG"
FAKE
chmod +x "$TMP/bin/"*
: > "$TMP/terminal.log"

common_env=(
  HOME="$TMP/home"
  PATH="$TMP/bin:$PATH"
  XDG_SESSION_TYPE=wayland
  XDG_CURRENT_DESKTOP=GNOME
  AUTO_CODE_STATE_DIR="$TMP/state"
  PROJECTS_FILE="$TMP/projects"
  CODE_ROOT="$TMP/code"
  TERMINALS_TEST_LOG="$TMP/terminal.log"
  TERMINALS_OPEN_INTERVAL_SECONDS=0
  TERMINALS_WORKSPACE_SETTLE_SECONDS=0
  TERMINALS_AUTO_INSTALL_GNOME_TERMINAL=0
  TERMINALS_ALLOW_PTYXIS_FALLBACK=1
)

for _ in 1 2; do
  set +e
  out="$(env "${common_env[@]}" "$ROOT/scripts/terminals.sh" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]]
  grep -Fq 'sessão ainda usa o código antigo' <<<"$out"
  grep -Fq 'Faça logout/login UMA vez' <<<"$out"
  [[ ! -e "$TMP/state/desktops/terminals.request" ]]
  [[ ! -s "$TMP/terminal.log" ]]
done

cmp -s -- "$ROOT/apps/desktops-gnome-extension/extension.js" "$TARGET/extension.js"
grep -Fq '"version": 15' "$TARGET/metadata.json"
[[ -s "$TMP/state/desktops/extension.reload-required" ]]

# Simula o novo processo gnome-shell após logout/login: o controlador v15
# publica as capacidades e remove o marker de recarga pendente.
cat > "$TMP/state/desktops/extension.ready" <<'READY'
version=15
controller=1
floating-label=0
window-placement=1
terminal-direct=1
terminal-placement-verified=1
READY
rm -f -- "$TMP/state/desktops/extension.reload-required"

(
  last=''
  handled=0
  for _ in $(seq 1 600); do
    req="$TMP/state/desktops/terminals.request"
    [[ -s "$req" ]] || { sleep 0.01; continue; }
    line="$(cat "$req")"
    token="${line%%$'\t'*}"
    [[ "$token" != "$last" ]] || { sleep 0.01; continue; }
    last="$token"
    count="$(tr '\t' '\n' <<<"$line" | sed -n 's/^count=//p' | head -n1)"
    workspace="$(tr '\t' '\n' <<<"$line" | sed -n 's/^workspace=//p' | head -n1)"
    slot="$(tr '\t' '\n' <<<"$line" | sed -n 's/^slot=//p' | head -n1)"
    handled=$((handled + 1))
    printf '%s\taction=direct\tcount=%s\tworkspace=%s\tslot=%s\tmonitor=2\tall_monitors=1\tvalid=1\n' \
      "$token" "$count" "$workspace" "$slot" > "$TMP/state/desktops/terminals.ready"
    for _wait in $(seq 1 200); do
      (( $(wc -l < "$TMP/terminal.log") >= handled )) && break
      sleep 0.01
    done
    printf '%s\tplaced=1\texpected=1\tcomplete=1\tworkspace=%s\tmonitor=2\n' "$token" "$workspace" > "$TMP/state/desktops/terminals.result"
    (( handled == count )) && exit 0
  done
  exit 5
) &
watcher=$!
env "${common_env[@]}" "$ROOT/scripts/terminals.sh" >/dev/null
wait "$watcher"
[[ "$(wc -l < "$TMP/terminal.log")" -eq 3 ]]

echo 'OK: controlador antigo é bloqueado até o logout/login e o fluxo direto funciona após a recarga.'
