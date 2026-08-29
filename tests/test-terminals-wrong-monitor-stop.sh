#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/terminals-wrong-monitor-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state/desktops" "$TMP/code/a"
printf 'a\n' > "$TMP/projects"

cat > "$TMP/bin/gsettings" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GSETTINGS_LOG"
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
  enable) exit 0 ;;
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
: > "$TMP/gsettings.log"

(
  for _ in $(seq 1 300); do
    req="$TMP/state/desktops/terminals.request"
    [[ -s "$req" ]] || { sleep 0.02; continue; }
    line="$(cat "$req")"
    token="${line%%$'\t'*}"
    count="$(tr '\t' '\n' <<<"$line" | sed -n 's/^count=//p' | head -n1)"
    workspace="$(tr '\t' '\n' <<<"$line" | sed -n 's/^workspace=//p' | head -n1)"
    slot="$(tr '\t' '\n' <<<"$line" | sed -n 's/^slot=//p' | head -n1)"
    printf '%s\taction=direct\tcount=%s\tworkspace=%s\tslot=%s\tmonitor=2\tall_monitors=1\tvalid=1\n' \
      "$token" "$count" "$workspace" "$slot" > "$TMP/state/desktops/terminals.ready"
    for _wait in $(seq 1 100); do
      [[ "$(wc -l < "$TMP/terminal.log")" -ge 1 ]] && break
      sleep 0.02
    done
    # Reproduz exatamente a falha real: controlador diz que concluiu, mas a
    # janela terminou em outro monitor. O script deve parar imediatamente.
    printf '%s\tplaced=1\texpected=1\tcomplete=1\tworkspace=%s\tmonitor=1\n' \
      "$token" "$workspace" > "$TMP/state/desktops/terminals.result"
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
  GSETTINGS_LOG="$TMP/gsettings.log" \
  TERMINALS_OPEN_INTERVAL_SECONDS=0 \
  "$ROOT/scripts/terminals.sh" 2>&1)"
rc=$?
set -e
wait "$watcher"

[[ "$rc" -ne 0 ]]
[[ "$(wc -l < "$TMP/terminal.log")" -eq 1 ]]
grep -Fq 'terminou no destino errado' <<<"$out"
grep -Fq 'esperado desktop=2, monitor=2' <<<"$out"
grep -Fq 'org.gnome.mutter workspaces-only-on-primary false' "$TMP/gsettings.log"

echo 'OK: monitor errado interrompe o lote no primeiro terminal; nenhum desktop seguinte é aberto.'
