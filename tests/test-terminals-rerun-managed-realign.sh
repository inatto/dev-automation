#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/terminals-rerun-realign-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state/desktops" "$TMP/code/a" "$TMP/code/b"
cat > "$TMP/projects" <<'PROJECTS'
a
b
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
  info) printf '  Version: 16\n  State: ACTIVE\n' ;;
  enable) ;;
esac
FAKE
cat > "$TMP/bin/ptyxis" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TERMINALS_TEST_LOG"
FAKE
chmod +x "$TMP/bin/"*
cat > "$TMP/state/desktops/extension.ready" <<'READY'
version=16
controller=1
floating-label=0
window-placement=1
terminal-direct=1
terminal-placement-verified=1
READY
# A presença do batch representa um lote anterior ainda vivo. O controlador
# falso confirma que as 4 janelas gerenciadas continuam abertas.
printf 'shell=fake\nmanaged=101\nmanaged=102\nmanaged=103\nmanaged=104\n' > "$TMP/state/desktops/terminals.batch"
: > "$TMP/terminal.log"
: > "$TMP/actions.log"

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
    count="$(tr '\t' '\n' <<<"$line" | sed -n 's/^count=//p' | head -n1)"
    printf '%s\n' "$action" >> "$TMP/actions.log"
    case "$action" in
      status)
        [[ "$count" == 4 ]]
        printf '%s\taction=status\tcount=4\tmanaged=4\tmissing=0\tuntracked=0\toverflow=0\tfirst_workspace=2\tmonitor=2\n' \
          "$token" > "$TMP/state/desktops/terminals.ready"
        printf '%s\tplaced=4\texpected=4\tcomplete=1\n' "$token" > "$TMP/state/desktops/terminals.result"
        handled=$((handled + 1))
        ;;
      reconcile)
        [[ "$count" == 4 ]]
        printf '%s\taction=reconcile\tcount=4\tmanaged=4\tmissing=0\tuntracked=0\toverflow=0\tfirst_workspace=2\tmonitor=2\n' \
          "$token" > "$TMP/state/desktops/terminals.ready"
        printf '%s\tplaced=4\texpected=4\tcomplete=1\n' "$token" > "$TMP/state/desktops/terminals.result"
        handled=$((handled + 1))
        (( handled == 2 )) && exit 0
        ;;
      *) exit 5 ;;
    esac
  done
  exit 4
) &
watcher=$!

out="$(env HOME="$TMP/home" PATH="$TMP/bin:$PATH" XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME \
  AUTO_CODE_STATE_DIR="$TMP/state" PROJECTS_FILE="$TMP/projects" CODE_ROOT="$TMP/code" \
  TERMINALS_TEST_LOG="$TMP/terminal.log" TERMINALS_OPEN_INTERVAL_SECONDS=0 \
  TERMINALS_WORKSPACE_SETTLE_SECONDS=0 TERMINALS_AUTO_INSTALL_GNOME_TERMINAL=0 TERMINALS_ALLOW_PTYXIS_FALLBACK=1 \
  "$ROOT/scripts/terminals/terminals.sh")"
wait "$watcher"

[[ "$(cat "$TMP/actions.log")" == $'status\nreconcile' ]]
[[ ! -s "$TMP/terminal.log" ]]
grep -Fq 'REPOSICIONAMENTO: 4 terminal(is) gerenciado(s) já estão abertos' <<<"$out"
grep -Fq 'nenhuma janela foi aberta ou fechada' <<<"$out"
! grep -Fq '^managed-reset$' "$TMP/actions.log"
! grep -Fq '^direct$' "$TMP/actions.log"
echo 'OK: nova execução de terminals reutiliza e reposiciona o lote existente sem fechar nem abrir janelas.'
