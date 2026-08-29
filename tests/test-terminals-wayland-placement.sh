#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/terminals-wayland-test-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state/desktops" \
  "$TMP/code/bots/dev-automation" \
  "$TMP/code/orgs/orbital/orbital-app" \
  "$TMP/code/orgs/orbital/orbital-ui"
cat > "$TMP/projects" <<'PROJECTS'
bots/dev-automation
orgs/orbital/orbital-app
orgs/orbital/orbital-ui
ignored/aggregate.zip
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
  info) printf '  Version: 15\n  State: ACTIVE\n' ;;
  enable) ;;
esac
FAKE
cat > "$TMP/bin/ptyxis" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TERMINALS_TEST_LOG"
FAKE
chmod +x "$TMP/bin/"*
cat > "$TMP/state/desktops/extension.ready" <<'READY'
version=15
controller=1
floating-label=0
window-placement=1
terminal-direct=1
terminal-placement-verified=1
READY
: > "$TMP/terminal.log"
: > "$TMP/actions.log"

# Controlador falso: confirma a ativação de um workspace, aguarda exatamente a
# janela daquele slot e só então libera o próximo pedido.
(
  last=''
  handled=0
  deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    req="$TMP/state/desktops/terminals.request"
    [[ -s "$req" ]] || { sleep 0.02; continue; }
    line="$(cat "$req")"
    token="${line%%$'\t'*}"
    [[ "$token" != "$last" ]] || { sleep 0.02; continue; }
    last="$token"

    action="$(tr '\t' '\n' <<<"$line" | sed -n 's/^action=//p' | head -n1)"
    count="$(tr '\t' '\n' <<<"$line" | sed -n 's/^count=//p' | head -n1)"
    workspace="$(tr '\t' '\n' <<<"$line" | sed -n 's/^workspace=//p' | head -n1)"
    slot="$(tr '\t' '\n' <<<"$line" | sed -n 's/^slot=//p' | head -n1)"

    case "$action" in
      direct)
        handled=$((handled + 1))
        [[ "$count" == 5 ]]
        [[ "$slot" == "$handled" ]]
        [[ "$workspace" == "$((handled + 1))" ]]
        printf '%s\t%s\t%s\n' "$action" "$workspace" "$slot" >> "$TMP/actions.log"
        printf '%s\taction=direct\tcount=%s\tworkspace=%s\tslot=%s\tmonitor=2\tall_monitors=1\tvalid=1\n' \
          "$token" "$count" "$workspace" "$slot" > "$TMP/state/desktops/terminals.ready"
        printf '%s\tplaced=0\texpected=1\tcomplete=0\n' "$token" > "$TMP/state/desktops/terminals.result"

        for _ in $(seq 1 200); do
          current="$(wc -l < "$TMP/terminal.log")"
          (( current >= handled )) && break
          sleep 0.02
        done
        [[ "$(wc -l < "$TMP/terminal.log")" -eq "$handled" ]]
        printf '%s\tplaced=1\texpected=1\tcomplete=1\tworkspace=%s\tmonitor=2\n' "$token" "$workspace" > "$TMP/state/desktops/terminals.result"
        (( handled == count )) && exit 0
        ;;
      *) exit 3 ;;
    esac
  done
  exit 2
) &
watcher=$!

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
)

out="$(env "${common_env[@]}" "$ROOT/scripts/terminals.sh")"
wait "$watcher"

[[ "$(wc -l < "$TMP/terminal.log")" -eq 5 ]]
[[ "$(cat "$TMP/actions.log")" == $'direct\t2\t1\ndirect\t3\t2\ndirect\t4\t3\ndirect\t5\t4\ndirect\t6\t5' ]]
sed -n '1p' "$TMP/terminal.log" | grep -Fq -- "--working-directory=$TMP/code/bots/dev-automation"
sed -n '2p' "$TMP/terminal.log" | grep -Fq -- "--working-directory=$TMP/code/orgs/orbital/orbital-app"
sed -n '3p' "$TMP/terminal.log" | grep -Fq -- "--working-directory=$TMP/code/orgs/orbital/orbital-ui"
sed -n '4p' "$TMP/terminal.log" | grep -Fq -- "--working-directory=$TMP/home"
sed -n '5p' "$TMP/terminal.log" | grep -Fq -- "--working-directory=$TMP/home"

grep -Fq 'FLUXO ÚNICO' <<<"$out"
grep -Fq 'Intervalo entre aberturas: 0 segundo(s).' <<<"$out"
grep -Fq 'sem segunda fase' <<<"$out"
! grep -Fq 'FASE: MOVIMENTAÇÃO' "$ROOT/scripts/terminals.sh"
! grep -Fq 'gnome_placement_prepare terminals reconcile' "$ROOT/scripts/terminals.sh"
grep -Fq 'TERMINALS_OPEN_INTERVAL_SECONDS:-1' "$ROOT/scripts/terminals.sh"
grep -Fq 'gnome_placement_prepare terminals direct' "$ROOT/scripts/terminals.sh"
grep -Fq 'workspaces-only-on-primary false' "$ROOT/scripts/terminals.sh"
grep -Fq "action === 'direct'" "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq 'workspace.activate(global.get_current_time())' "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq "terminalSession.mode === 'direct'" "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq '_confirmDirectTerminalPlacement(' "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq 'status|open|direct|reconcile|reset|managed-reset' "$ROOT/scripts/gnome-window-placement.sh"

: > "$TMP/reset.log"
(
  previous="$(head -n1 "$TMP/state/desktops/terminals.request" 2>/dev/null || true)"
  for _ in $(seq 1 300); do
    req="$TMP/state/desktops/terminals.request"
    [[ -s "$req" ]] || { sleep 0.02; continue; }
    line="$(cat "$req")"
    [[ "${line%%$'\t'*}" != "${previous%%$'\t'*}" ]] || { sleep 0.02; continue; }
    token="${line%%$'\t'*}"
    action="$(tr '\t' '\n' <<<"$line" | sed -n 's/^action=//p' | head -n1)"
    [[ "$action" == reset ]] || exit 5
    printf '%s\n' "$action" > "$TMP/reset.log"
    printf '%s\taction=reset\tcount=5\tmanaged=5\tmissing=0\tuntracked=0\toverflow=0\tfirst_workspace=2\tmonitor=2\n' \
      "$token" > "$TMP/state/desktops/terminals.ready"
    exit 0
  done
  exit 6
) &
reset_watcher=$!
env "${common_env[@]}" "$ROOT/scripts/terminals.sh" --reset >/dev/null
wait "$reset_watcher"
grep -Fxq reset "$TMP/reset.log"

echo 'OK: terminals ativa cada desktop e abre ali o terminal da pasta correta, um por vez, sem segunda fase.'
