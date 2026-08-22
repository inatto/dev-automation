#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/terminals-wayland-test-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state/desktops" "$TMP/code/bots/dev-automation" "$TMP/code/orgs/orbital/orbital-app" "$TMP/code/orgs/orbital/orbital-ui"
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
  info)
    printf '  Version: %s\n  State: ACTIVE\n' "${TERMINALS_FAKE_EXT_VERSION:-10}"
    exit 0
    ;;
  enable) exit 0 ;;
esac
exit 0
FAKE
cat > "$TMP/bin/ptyxis" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TERMINALS_TEST_LOG"
FAKE
chmod +x "$TMP/bin/"*
cat > "$TMP/state/desktops/extension.ready" <<'READY'
version=10
controller=1
floating-label=0
window-placement=1
READY
: > "$TMP/terminal.log"
: > "$TMP/actions.log"

# Controlador falso: só confirma UMA janela por vez, com atraso. Se o backend
# disparar uma rajada antes da confirmação, marca corrida e o teste falha.
(
  last=''
  managed=0
  open_token=''
  observed=0
  deadline=$((SECONDS + 40))
  while (( SECONDS < deadline )); do
    req="$TMP/state/desktops/terminals.request"
    if [[ -s "$req" ]]; then
      line="$(cat "$req")"
      token="${line%%$'\t'*}"
      if [[ "$token" != "$last" ]]; then
        last="$token"
        action="$(tr '\t' '\n' <<<"$line" | sed -n 's/^action=//p' | head -n1)"
        count="$(tr '\t' '\n' <<<"$line" | sed -n 's/^count=//p' | head -n1)"
        printf '%s\n' "$action" >> "$TMP/actions.log"
        case "$action" in
          status)
            missing=$((count - managed))
            printf '%s\taction=status\tcount=%s\tmanaged=%s\tmissing=%s\tuntracked=0\toverflow=0\tfirst_workspace=2\tmonitor=2\n' \
              "$token" "$count" "$managed" "$missing" > "$TMP/state/desktops/terminals.ready"
            printf '%s\tplaced=%s\texpected=%s\tcomplete=1\n' "$token" "$managed" "$managed" > "$TMP/state/desktops/terminals.result"
            ;;
          open)
            missing=$((count - managed))
            open_token="$token"
            observed=0
            printf '%s\taction=open\tcount=%s\tmanaged=%s\tmissing=%s\tuntracked=0\toverflow=0\tfirst_workspace=2\tmonitor=2\n' \
              "$token" "$count" "$managed" "$missing" > "$TMP/state/desktops/terminals.ready"
            printf '%s\tplaced=0\texpected=%s\tcomplete=0\n' "$token" "$missing" > "$TMP/state/desktops/terminals.result"
            ;;
          reconcile)
            printf '%s\taction=reconcile\tcount=%s\tmanaged=%s\tmissing=0\tuntracked=0\toverflow=0\tfirst_workspace=2\tmonitor=2\n' \
              "$token" "$count" "$managed" > "$TMP/state/desktops/terminals.ready"
            printf '%s\tplaced=%s\texpected=%s\tcomplete=1\n' "$token" "$count" "$count" > "$TMP/state/desktops/terminals.result"
            ;;
          reset)
            printf '%s\taction=reset\tcount=%s\tmanaged=%s\tmissing=0\tuntracked=0\toverflow=0\tfirst_workspace=2\tmonitor=2\n' \
              "$token" "$count" "$managed" > "$TMP/state/desktops/terminals.ready"
            printf '%s\tplaced=%s\texpected=%s\tcomplete=1\n' "$token" "$managed" "$managed" > "$TMP/state/desktops/terminals.result"
            managed=0
            ;;
          *) exit 3 ;;
        esac
      fi
    fi

    if [[ -n "$open_token" ]]; then
      current="$(wc -l < "$TMP/terminal.log")"
      if (( current > observed )); then
        # Dá tempo para uma implementação defeituosa disparar a rajada.
        sleep 0.15
        later="$(wc -l < "$TMP/terminal.log")"
        if (( later > observed + 1 )); then
          : > "$TMP/race.detected"
          exit 4
        fi
        observed=$current
        complete=0
        (( observed >= 3 )) && complete=1
        printf '%s\tplaced=%s\texpected=3\tcomplete=%s\n' "$open_token" "$observed" "$complete" > "$TMP/state/desktops/terminals.result"
        if (( complete == 1 )); then
          managed=3
          open_token=''
        fi
      fi
    fi

    [[ "$(tail -n 4 "$TMP/actions.log" 2>/dev/null | tr '\n' ' ')" == *"status open status reconcile"* ]] && exit 0
    sleep 0.03
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
  TERMINALS_OPEN_SETTLE_SECONDS=0
)

out1="$(env "${common_env[@]}" "$ROOT/scripts/terminals.sh")"
[[ "$(wc -l < "$TMP/terminal.log")" -eq 3 ]]
[[ ! -e "$TMP/race.detected" ]]
grep -Fq 'FASE: ABERTURA' <<<"$out1"
grep -Fq 'Abrindo UM POR VEZ' <<<"$out1"
grep -Fq 'esperando confirmação antes do próximo' <<<"$out1"
grep -Fq 'Nesta chamada NÃO haverá movimentação entre workspaces.' <<<"$out1"
grep -Fq 'PRÓXIMA CHAMADA: terminals fará somente a MOVIMENTAÇÃO e MAXIMIZAÇÃO' <<<"$out1"
grep -Fq -- '--new-window --working-directory=' "$TMP/terminal.log"

after_first="$(wc -l < "$TMP/terminal.log")"
out2="$(env "${common_env[@]}" "$ROOT/scripts/terminals.sh")"
[[ "$(wc -l < "$TMP/terminal.log")" -eq "$after_first" ]]
grep -Fq 'FASE: MOVIMENTAÇÃO' <<<"$out2"
grep -Fq 'ABERTURA: 0.' <<<"$out2"
grep -Fq 'workspaces 2..4' <<<"$out2"
grep -Fq 'monitor direito e MAXIMIZADO' <<<"$out2"
grep -Fq 'próximas chamadas apenas reconciliam' <<<"$out2"
wait "$watcher"

[[ "$(tr '\n' ' ' < "$TMP/actions.log")" == *"status open status reconcile"* ]]
grep -Fq 'gnome_placement_wait_min terminals placed' "$ROOT/scripts/terminals.sh"
! grep -Fq 'for ((i=1; i<=missing; i++))' "$ROOT/scripts/terminals.sh"
grep -Fq '_scheduleTerminalPlacement' "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq 'window.maximize()' "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq 'overflowSequences' "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq '_closeTerminalWindows(status.overflow)' "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq 'index >= 1 && index <= target' "$ROOT/apps/desktops-gnome-extension/extension.js"

# Reset deve funcionar até com o controlador v9 ainda carregado, justamente para
# limpar imediatamente o excesso criado pela versão anterior.
cat > "$TMP/state/desktops/extension.ready" <<'READY_V9'
version=9
controller=1
floating-label=0
window-placement=1
READY_V9
: > "$TMP/reset.actions"
(
  for _ in $(seq 1 200); do
    req="$TMP/state/desktops/terminals.request"
    [[ -s "$req" ]] || { sleep 0.03; continue; }
    line="$(cat "$req")"
    token="${line%%$'\t'*}"
    action="$(tr '\t' '\n' <<<"$line" | sed -n 's/^action=//p' | head -n1)"
    [[ "$action" == reset ]] || { sleep 0.03; continue; }
    printf '%s\n' "$action" > "$TMP/reset.actions"
    printf '%s\taction=reset\tcount=3\tmanaged=3\tmissing=0\tuntracked=0\toverflow=0\tfirst_workspace=2\tmonitor=2\n' "$token" > "$TMP/state/desktops/terminals.ready"
    printf '%s\tplaced=3\texpected=3\tcomplete=1\n' "$token" > "$TMP/state/desktops/terminals.result"
    exit 0
  done
  exit 5
) &
reset_watcher=$!
TERMINALS_FAKE_EXT_VERSION=9 env "${common_env[@]}" "$ROOT/scripts/terminals.sh" --reset >/dev/null
wait "$reset_watcher"
grep -Fxq reset "$TMP/reset.actions"

echo 'OK: terminals abre sequencialmente sem rajada, move/maximiza na segunda chamada e mantém reset compatível com v9.'
