#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/terminals-project-order-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state/desktops" "$TMP/code/a/apps/child" "$TMP/code/new"
cat > "$TMP/projects" <<'PROJECTS'
a
a/apps/child
new
PROJECTS
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
: > "$TMP/order.log"

(
  last=''
  handled=0
  deadline=$((SECONDS + 20))
  while (( SECONDS < deadline )); do
    req="$TMP/state/desktops/terminals.request"
    [[ -s "$req" ]] || { sleep 0.02; continue; }
    line="$(cat "$req")"
    token="${line%%$'\t'*}"
    [[ "$token" != "$last" ]] || { sleep 0.02; continue; }
    last="$token"
    action="$(tr '\t' '\n' <<<"$line" | sed -n 's/^action=//p' | head -n1)"
    workspace="$(tr '\t' '\n' <<<"$line" | sed -n 's/^workspace=//p' | head -n1)"
    slot="$(tr '\t' '\n' <<<"$line" | sed -n 's/^slot=//p' | head -n1)"
    count="$(tr '\t' '\n' <<<"$line" | sed -n 's/^count=//p' | head -n1)"
    [[ "$action" == direct ]]
    handled=$((handled + 1))
    printf '%s:%s\n' "$slot" "$workspace" >> "$TMP/order.log"
    printf '%s\taction=direct\tcount=%s\tworkspace=%s\tslot=%s\tmonitor=2\tall_monitors=1\tvalid=1\n' \
      "$token" "$count" "$workspace" "$slot" > "$TMP/state/desktops/terminals.ready"
    for _ in $(seq 1 100); do
      (( $(wc -l < "$TMP/terminal.log") >= handled )) && break
      sleep 0.02
    done
    printf '%s\tplaced=1\texpected=1\tcomplete=1\tworkspace=%s\tmonitor=2\n' "$token" "$workspace" > "$TMP/state/desktops/terminals.result"
    (( handled == count )) && exit 0
  done
  exit 4
) &
watcher=$!

env HOME="$TMP/home" PATH="$TMP/bin:$PATH" XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME \
  AUTO_CODE_STATE_DIR="$TMP/state" PROJECTS_FILE="$TMP/projects" CODE_ROOT="$TMP/code" \
  TERMINALS_TEST_LOG="$TMP/terminal.log" TERMINALS_OPEN_INTERVAL_SECONDS=0 \
  TERMINALS_WORKSPACE_SETTLE_SECONDS=0 TERMINALS_AUTO_INSTALL_GNOME_TERMINAL=0 TERMINALS_ALLOW_PTYXIS_FALLBACK=1 \
  "$ROOT/scripts/terminals.sh" >/dev/null
wait "$watcher"

[[ "$(cat "$TMP/order.log")" == $'1:2\n2:3\n3:4\n4:5' ]]
sed -n '1p' "$TMP/terminal.log" | grep -Fq -- "--working-directory=$TMP/code/a"
sed -n '2p' "$TMP/terminal.log" | grep -Fq -- "--working-directory=$TMP/code/new"
sed -n '3p' "$TMP/terminal.log" | grep -Fq -- "--working-directory=$TMP/home"
sed -n '4p' "$TMP/terminal.log" | grep -Fq -- "--working-directory=$TMP/home"

! grep -Fq -- '--working-directory=$TMP/code/a/apps/child' "$TMP/terminal.log"
echo 'OK: a ordem dos projetos raiz define desktop/pasta; subprojeto cadastrado em <pai>/apps não consome desktop.'
