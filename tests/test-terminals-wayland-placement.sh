#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/terminals-wayland-test-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state/desktops"
printf 'bots/dev-automation\norgs/orbital/orbital-app\norgs/orbital/orbital-ui\n' > "$TMP/projects"

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
      printf '  Version: 9\n  State: ACTIVE\n'
    else
      printf '  Version: 9\n  State: INACTIVE\n'
    fi
    exit 0
    ;;
  enable)
    dir="${AUTO_CODE_STATE_DIR:-$HOME/.local/state/dev-automation}/desktops"
    mkdir -p "$dir"
    cat > "$dir/extension.ready" <<'READY'
version=9
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
cat > "$TMP/state/desktops/extension.ready" <<'READY'
version=9
controller=1
floating-label=0
window-placement=1
READY
: > "$TMP/terminal.log"
: > "$TMP/actions.log"

# Simula controlador GNOME v9: 1ª chamada status->open; 2ª status->reconcile.
(
  last=''
  managed=0
  deadline=$((SECONDS + 30))
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
            printf '%s\taction=status\tcount=%s\tmanaged=%s\tmissing=%s\tuntracked=0\tfirst_workspace=2\tmonitor=2\n' \
              "$token" "$count" "$managed" "$missing" > "$TMP/state/desktops/terminals.ready"
            printf '%s\tplaced=%s\texpected=%s\tcomplete=1\n' "$token" "$managed" "$managed" > "$TMP/state/desktops/terminals.result"
            ;;
          open)
            missing=$((count - managed))
            printf '%s\taction=open\tcount=%s\tmanaged=%s\tmissing=%s\tuntracked=0\tfirst_workspace=2\tmonitor=2\n' \
              "$token" "$count" "$managed" "$missing" > "$TMP/state/desktops/terminals.ready"
            start_lines="$(wc -l < "$TMP/terminal.log")"
            for _ in $(seq 1 200); do
              current="$(wc -l < "$TMP/terminal.log")"
              if (( current - start_lines >= missing )); then
                managed=$count
                printf '%s\tplaced=%s\texpected=%s\tcomplete=1\n' "$token" "$missing" "$missing" > "$TMP/state/desktops/terminals.result"
                break
              fi
              sleep 0.03
            done
            ;;
          reconcile)
            printf '%s\taction=reconcile\tcount=%s\tmanaged=%s\tmissing=0\tuntracked=0\tfirst_workspace=2\tmonitor=2\n' \
              "$token" "$count" "$managed" > "$TMP/state/desktops/terminals.ready"
            printf '%s\tplaced=%s\texpected=%s\tcomplete=1\n' "$token" "$count" "$count" > "$TMP/state/desktops/terminals.result"
            ;;
          *) exit 3 ;;
        esac
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
  TERMINALS_TEST_LOG="$TMP/terminal.log"
)

out1="$(env "${common_env[@]}" "$ROOT/scripts/terminals.sh")"
[[ "$(wc -l < "$TMP/terminal.log")" -eq 3 ]]
grep -Fq 'FASE: ABERTURA' <<<"$out1"
grep -Fq 'Nesta chamada NÃO haverá movimentação entre workspaces.' <<<"$out1"
grep -Fq 'PRÓXIMA CHAMADA: terminals fará somente a MOVIMENTAÇÃO' <<<"$out1"
grep -Fq -- '--new-window' "$TMP/terminal.log"

after_first="$(wc -l < "$TMP/terminal.log")"
out2="$(env "${common_env[@]}" "$ROOT/scripts/terminals.sh")"
[[ "$(wc -l < "$TMP/terminal.log")" -eq "$after_first" ]]
grep -Fq 'FASE: MOVIMENTAÇÃO' <<<"$out2"
grep -Fq 'ABERTURA: 0.' <<<"$out2"
grep -Fq 'workspaces 2..4' <<<"$out2"
grep -Fq 'próximas chamadas apenas reconciliam' <<<"$out2"
wait "$watcher"

[[ "$(tr '\n' ' ' < "$TMP/actions.log")" == *"status open status reconcile"* ]]
grep -Fq 'get_stable_sequence' "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq '_terminalAssignments' "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq 'get_maximize_flags' "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq 'index >= 1 && index <= target' "$ROOT/apps/desktops-gnome-extension/extension.js"

echo 'OK: terminals usa duas fases, não duplica no segundo comando e limita a LAZER+projetos (sem lrdp).'
