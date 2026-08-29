#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/terminals-missing-slot-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p \
  "$TMP/bin" \
  "$TMP/home" \
  "$TMP/state/desktops" \
  "$TMP/code/a" \
  "$TMP/code/b" \
  "$TMP/code/c"

cat > "$TMP/projects" <<'PROJECTS'
a
b
c
PROJECTS

cat > "$TMP/bin/gnome-shell" <<'FAKE'
#!/usr/bin/env bash
printf 'GNOME Shell 50.1\n'
FAKE
cat > "$TMP/bin/gnome-extensions" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  info) printf '  Version: 13\n  State: ACTIVE\n' ;;
  enable) ;;
esac
FAKE
cat > "$TMP/bin/ptyxis" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TERMINALS_TEST_LOG"
FAKE
chmod +x "$TMP/bin/"*

cat > "$TMP/state/desktops/extension.ready" <<'READY'
version=13
controller=1
floating-label=0
window-placement=1
READY
: > "$TMP/terminal.log"
: > "$TMP/actions.log"

# Há cinco destinos: a, b, c, lrdp1 e lrdp2. O slot 2 (b) desapareceu,
# mas os slots 1, 3, 4 e 5 continuam mapeados. A implementação antiga usava
# managed=4 e abria o último destino, deslocando a associação inteira.
(
  last=''
  open_token=''
  deadline=$((SECONDS + 20))
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
            [[ "$count" == 5 ]]
            printf '%s\taction=status\tcount=5\tmanaged=4\tmissing=1\tmissing_slots=2\tlegacy=0\tuntracked=0\toverflow=0\tfirst_workspace=2\tmonitor=2\n' \
              "$token" > "$TMP/state/desktops/terminals.ready"
            printf '%s\tplaced=4\texpected=4\tcomplete=1\n' "$token" > "$TMP/state/desktops/terminals.result"
            ;;
          open)
            open_token="$token"
            printf '%s\taction=open\tcount=5\tmanaged=4\tmissing=1\tmissing_slots=2\tlegacy=0\tuntracked=0\toverflow=0\tfirst_workspace=2\tmonitor=2\n' \
              "$token" > "$TMP/state/desktops/terminals.ready"
            printf '%s\tplaced=0\texpected=1\tcomplete=0\n' "$token" > "$TMP/state/desktops/terminals.result"
            ;;
          *) exit 3 ;;
        esac
      fi
    fi

    if [[ -n "$open_token" && "$(wc -l < "$TMP/terminal.log")" -ge 1 ]]; then
      printf '%s\tplaced=1\texpected=1\tcomplete=1\n' "$open_token" > "$TMP/state/desktops/terminals.result"
      exit 0
    fi
    sleep 0.03
  done
  exit 4
) &
watcher=$!

out="$(env \
  HOME="$TMP/home" \
  PATH="$TMP/bin:$PATH" \
  XDG_SESSION_TYPE=wayland \
  XDG_CURRENT_DESKTOP=GNOME \
  AUTO_CODE_STATE_DIR="$TMP/state" \
  PROJECTS_FILE="$TMP/projects" \
  CODE_ROOT="$TMP/code" \
  TERMINALS_TEST_LOG="$TMP/terminal.log" \
  TERMINALS_OPEN_SETTLE_SECONDS=0 \
  "$ROOT/scripts/terminals.sh")"
wait "$watcher"

[[ "$(wc -l < "$TMP/terminal.log")" -eq 1 ]]
grep -Fq -- "--working-directory=$TMP/code/b" "$TMP/terminal.log"
! grep -Fq -- "--working-directory=$TMP/home" "$TMP/terminal.log"
grep -Fq 'ABRINDO SLOT 2/5: b' <<<"$out"
[[ "$(tr '\n' ' ' < "$TMP/actions.log")" == 'status open ' ]]

echo 'OK: uma lacuna intermediária abre exatamente o projeto do slot ausente, sem deslocar os terminais seguintes.'
