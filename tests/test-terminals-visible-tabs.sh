#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/terminals-visible-tabs-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state/desktops" \
  "$TMP/code/orgs/orbital/orbital-app/deploy/local" \
  "$TMP/code/orgs/orbital/orbital-app/deploy/remote"
: > "$TMP/code/orgs/orbital/orbital-app/deploy/local/setup.sh"
: > "$TMP/code/orgs/orbital/orbital-app/deploy/remote/setup.sh"
printf 'orgs/orbital/orbital-app\n' > "$TMP/projects"

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
cat > "$TMP/bin/gnome-terminal" <<'FAKE'
#!/usr/bin/env bash
mode=''
for arg in "$@"; do
  [[ "$arg" == --window ]] && mode=window
  [[ "$arg" == --tab ]] && mode=tab
done
printf 'mode=%s screen=%s gnome-terminal %s\n' "$mode" "${GNOME_TERMINAL_SCREEN:-external}" "$*" >> "$TERMINALS_TEST_LOG"
# Simula o GNOME Terminal real: o processo executado dentro da primeira aba
# recebe a identidade dessa aba/janela. É essa herança que deve originar --tab.
if [[ "$mode" == window ]]; then
  args=("$@")
  for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == -- ]]; then
      export GNOME_TERMINAL_SCREEN='/org/gnome/Terminal/screen/project_test'
      export GNOME_TERMINAL_SERVICE=':test.service'
      "${args[@]:i+1}" >/dev/null 2>&1
      break
    fi
  done
fi
FAKE
cat > "$TMP/bin/ptyxis" <<'FAKE'
#!/usr/bin/env bash
printf 'ptyxis %s\n' "$*" >> "$TERMINALS_TEST_LOG"
FAKE
cat > "$TMP/bin/orbital-app-auto" <<'FAKE'
#!/usr/bin/env bash
sleep 1
FAKE
cat > "$TMP/bin/remote-orbital-app-auto" <<'FAKE'
#!/usr/bin/env bash
sleep 0.1
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

(
  last=''
  handled=0
  deadline=$((SECONDS + 15))
  while (( SECONDS < deadline )); do
    req="$TMP/state/desktops/terminals.request"
    [[ -s "$req" ]] || { sleep 0.02; continue; }
    line="$(cat "$req")"
    token="${line%%$'\t'*}"
    [[ "$token" != "$last" ]] || { sleep 0.02; continue; }
    last="$token"
    action="$(tr '\t' '\n' <<<"$line" | sed -n 's/^action=//p' | head -n1)"
    [[ "$action" == direct ]] || exit 3
    count="$(tr '\t' '\n' <<<"$line" | sed -n 's/^count=//p' | head -n1)"
    workspace="$(tr '\t' '\n' <<<"$line" | sed -n 's/^workspace=//p' | head -n1)"
    slot="$(tr '\t' '\n' <<<"$line" | sed -n 's/^slot=//p' | head -n1)"
    handled=$((handled + 1))
    printf '%s\taction=direct\tcount=%s\tworkspace=%s\tslot=%s\tmonitor=2\tall_monitors=1\tvalid=1\n' \
      "$token" "$count" "$workspace" "$slot" > "$TMP/state/desktops/terminals.ready"
    for _ in $(seq 1 150); do
      (( $(grep -c '^mode=window ' "$TMP/terminal.log" || true) >= handled )) && break
      sleep 0.02
    done
    printf '%s\tplaced=1\texpected=1\tcomplete=1\tworkspace=%s\tmonitor=2\n' \
      "$token" "$workspace" > "$TMP/state/desktops/terminals.result"
    (( handled == count )) && exit 0
  done
  exit 4
) &
watcher=$!

env HOME="$TMP/home" PATH="$TMP/bin:$PATH" XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME \
  AUTO_CODE_STATE_DIR="$TMP/state" PROJECTS_FILE="$TMP/projects" CODE_ROOT="$TMP/code" \
  TERMINALS_TEST_LOG="$TMP/terminal.log" TERMINALS_OPEN_INTERVAL_SECONDS=0 \
  TERMINALS_WORKSPACE_SETTLE_SECONDS=0 TERMINALS_AUTO_INSTALL_GNOME_TERMINAL=0 \
  "$ROOT/scripts/terminals.sh" >/dev/null
wait "$watcher"
for _ in $(seq 1 100); do
  (( $(grep -c '^mode=tab ' "$TMP/terminal.log" || true) >= 1 )) && break
  sleep 0.02
done

! grep -q 'ptyxis ' "$TMP/terminal.log"
[[ "$(grep -c '^mode=window ' "$TMP/terminal.log")" -eq 3 ]]
[[ "$(grep -c '^mode=tab ' "$TMP/terminal.log")" -eq 1 ]]
grep '^mode=window ' "$TMP/terminal.log" | head -n1 | \
  grep -F -- '--title=Orbital App Auto' | grep -Fq -- 'orbital-app-auto'
grep '^mode=tab ' "$TMP/terminal.log" | \
  grep -F -- '--title=Remote Orbital App Auto' | grep -Fq -- 'remote-orbital-app-auto'
grep '^mode=tab ' "$TMP/terminal.log" | \
  grep -Fq 'screen=/org/gnome/Terminal/screen/project_test'
! grep '^mode=tab screen=external ' "$TMP/terminal.log" >/dev/null

grep -Fq 'if path="$(command -v gnome-terminal 2>/dev/null)"' "$ROOT/scripts/terminals.sh"
grep -Fq 'TERMINALS_WORKSPACE_SETTLE_SECONDS:-1' "$ROOT/scripts/terminals.sh"
grep -Fq 'sleep "$WORKSPACE_SETTLE_SECONDS"' "$ROOT/scripts/terminals.sh"
grep -Fq 'sudo apt-get install -y gnome-terminal' "$ROOT/scripts/terminals.sh"

echo 'OK: Remote nasce dentro da aba Local, herda a janela GNOME correta e não vira janela independente.'
