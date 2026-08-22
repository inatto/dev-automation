#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/terminals-order-reset-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state/desktops" "$TMP/code/a" "$TMP/code/new" "$TMP/projects-dir"
cat > "$TMP/projects" <<'PROJECTS'
a
new
PROJECTS
cat > "$TMP/bin/gnome-shell" <<'FAKE'
#!/usr/bin/env bash
printf 'GNOME Shell 50.1\n'
FAKE
cat > "$TMP/bin/gnome-extensions" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  info) printf '  Version: 12\n  State: ACTIVE\n' ;;
  enable) ;;
esac
FAKE
cat > "$TMP/bin/ptyxis" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TERMINALS_TEST_LOG"
FAKE
cat > "$TMP/bin/gsettings" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$TMP/bin/"*
cat > "$TMP/state/desktops/extension.ready" <<'READY'
version=12
controller=1
floating-label=0
window-placement=1
READY
# Simula lote da configuração anterior: isso não pode ser reaproveitado após inserir/reordenar projeto.
printf 'shell=old\nmanaged=123\n' > "$TMP/state/desktops/terminals.batch"
printf 'assinatura-antiga\n' > "$TMP/state/desktops/terminals.projects.sha256"
: > "$TMP/terminal.log"
: > "$TMP/actions.log"
(
  last=''
  open_token=''
  count=0
  observed=0
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
          managed-reset)
            printf '%s\taction=managed-reset\tcount=%s\tmanaged=1\tmissing=%s\tuntracked=0\toverflow=0\tfirst_workspace=2\tmonitor=2\n' "$token" "$count" "$((count-1))" > "$TMP/state/desktops/terminals.ready"
            printf '%s\tplaced=1\texpected=1\tcomplete=1\n' "$token" > "$TMP/state/desktops/terminals.result"
            rm -f "$TMP/state/desktops/terminals.batch"
            ;;
          status)
            printf '%s\taction=status\tcount=%s\tmanaged=0\tmissing=%s\tuntracked=0\toverflow=0\tfirst_workspace=2\tmonitor=2\n' "$token" "$count" "$count" > "$TMP/state/desktops/terminals.ready"
            printf '%s\tplaced=0\texpected=0\tcomplete=1\n' "$token" > "$TMP/state/desktops/terminals.result"
            ;;
          open)
            open_token="$token"; observed=0
            printf '%s\taction=open\tcount=%s\tmanaged=0\tmissing=%s\tuntracked=0\toverflow=0\tfirst_workspace=2\tmonitor=2\n' "$token" "$count" "$count" > "$TMP/state/desktops/terminals.ready"
            printf '%s\tplaced=0\texpected=%s\tcomplete=0\n' "$token" "$count" > "$TMP/state/desktops/terminals.result"
            ;;
        esac
      fi
    fi
    if [[ -n "$open_token" ]]; then
      current="$(wc -l < "$TMP/terminal.log")"
      if (( current > observed )); then
        observed="$current"
        complete=0; (( observed >= count )) && complete=1
        printf '%s\tplaced=%s\texpected=%s\tcomplete=%s\n' "$open_token" "$observed" "$count" "$complete" > "$TMP/state/desktops/terminals.result"
        (( complete == 1 )) && exit 0
      fi
    fi
    sleep 0.03
  done
  exit 9
) &
watcher=$!
env HOME="$TMP/home" PATH="$TMP/bin:$PATH" XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME \
  AUTO_CODE_STATE_DIR="$TMP/state" PROJECTS_FILE="$TMP/projects" CODE_ROOT="$TMP/code" \
  TERMINALS_TEST_LOG="$TMP/terminal.log" TERMINALS_OPEN_SETTLE_SECONDS=0 \
  "$ROOT/scripts/terminals.sh" >/tmp/terminals-order-reset.out
wait "$watcher"
[[ "$(tr '\n' ' ' < "$TMP/actions.log")" == "managed-reset status open " ]]
[[ "$(wc -l < "$TMP/terminal.log")" -eq 4 ]]
[[ -s "$TMP/state/desktops/terminals.projects.sha256" ]]
! grep -Fxq 'assinatura-antiga' "$TMP/state/desktops/terminals.projects.sha256"
grep -Fq 'lista/ordem de projetos mudou' /tmp/terminals-order-reset.out
rm -f /tmp/terminals-order-reset.out
echo 'OK: mudança de lista/ordem descarta apenas o lote gerenciado antigo antes de reabrir em ordem canônica.'
