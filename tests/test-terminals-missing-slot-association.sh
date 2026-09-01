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
: > "$TMP/request.log"

# Reproduz a resposta do controlador antigo: reconhece action=direct, mas não
# devolve workspace/slot/valid. O script deve rejeitar o protocolo e não abrir
# sequer o primeiro terminal, em vez de adivinhar uma associação errada.
(
  for _ in $(seq 1 300); do
    req="$TMP/state/desktops/terminals.request"
    [[ -s "$req" ]] || { sleep 0.02; continue; }
    line="$(cat "$req")"
    token="${line%%$'\t'*}"
    workspace="$(tr '\t' '\n' <<<"$line" | sed -n 's/^workspace=//p' | head -n1)"
    slot="$(tr '\t' '\n' <<<"$line" | sed -n 's/^slot=//p' | head -n1)"
    printf '%s:%s\n' "$workspace" "$slot" > "$TMP/request.log"
    printf '%s\taction=direct\tcount=5\tmanaged=0\tmissing=5\n' \
      "$token" > "$TMP/state/desktops/terminals.ready"
    exit 0
  done
  exit 4
) &
watcher=$!

set +e
out="$(env \
  HOME="$TMP/home" \
  PATH="$TMP/bin:$PATH" \
  XDG_SESSION_TYPE=wayland \
  XDG_CURRENT_DESKTOP=GNOME \
  AUTO_CODE_STATE_DIR="$TMP/state" \
  PROJECTS_FILE="$TMP/projects" \
  CODE_ROOT="$TMP/code" \
  TERMINALS_TEST_LOG="$TMP/terminal.log" \
  TERMINALS_OPEN_INTERVAL_SECONDS=0 \
  TERMINALS_WORKSPACE_SETTLE_SECONDS=0 \
  TERMINALS_AUTO_INSTALL_GNOME_TERMINAL=0 \
  TERMINALS_ALLOW_PTYXIS_FALLBACK=1 \
  "$ROOT/scripts/terminals.sh" 2>&1)"
rc=$?
set -e
wait "$watcher"

[[ "$rc" -ne 0 ]]
[[ ! -s "$TMP/terminal.log" ]]
[[ "$(cat "$TMP/request.log")" == '2:1' ]]
grep -Fq "protocolo incompatível para 'terminals/direct'" <<<"$out"
grep -Fq 'não suporta a associação direta desktop/slot' <<<"$out"
! grep -Fq 'desktop=?' <<<"$out"
! grep -Fq 'slot=?' <<<"$out"

echo 'OK: resposta antiga sem desktop/slot é bloqueada antes de abrir qualquer terminal.'
