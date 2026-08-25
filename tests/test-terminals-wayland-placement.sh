#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/terminals-wayland-test-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.local/state/dev-automation/desktops" \
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
  info) printf '  Version: 13\n  State: ACTIVE\n'; exit 0 ;;
  enable) exit 0 ;;
esac
exit 0
FAKE
cat > "$TMP/bin/ptyxis" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TERMINALS_TEST_LOG"
FAKE
chmod +x "$TMP/bin/"*
cat > "$TMP/home/.local/state/dev-automation/desktops/extension.ready" <<'READY'
version=13
controller=1
floating-label=0
window-placement=1
READY
: > "$TMP/terminal.log"
: > "$TMP/actions.log"

watch_once() {
  local status_missing="$1" status_indices="$2" expected_actions="$3"
  (
    last=''
    deadline=$((SECONDS + 30))
    while (( SECONDS < deadline )); do
      req="$TMP/home/.local/state/dev-automation/desktops/terminals.request"
      [[ -s "$req" ]] || { sleep 0.03; continue; }
      line="$(cat "$req")"
      token="${line%%$'\t'*}"
      [[ "$token" != "$last" ]] || { sleep 0.03; continue; }
      last="$token"
      action="$(tr '\t' '\n' <<<"$line" | sed -n 's/^action=//p' | head -n1)"
      count="$(tr '\t' '\n' <<<"$line" | sed -n 's/^count=//p' | head -n1)"
      project="$(tr '\t' '\n' <<<"$line" | sed -n 's/^project=//p' | head -n1)"
      case "$action" in
        status)
          printf 'status\n' >> "$TMP/actions.log"
          managed=$((count - status_missing))
          printf '%s\taction=status\tcount=%s\tmanaged=%s\tmissing=%s\tmissing_indices=%s\tuntracked=0\toverflow=0\tfirst_workspace=2\tmonitor=2\n' \
            "$token" "$count" "$managed" "$status_missing" "$status_indices" > "$TMP/home/.local/state/dev-automation/desktops/terminals.ready"
          printf '%s\tplaced=%s\texpected=%s\tcomplete=1\n' "$token" "$managed" "$managed" > "$TMP/home/.local/state/dev-automation/desktops/terminals.result"
          ;;
        open)
          printf 'open:%s\n' "$project" >> "$TMP/actions.log"
          printf '%s\taction=open\tcount=%s\tmanaged=%s\tmissing=1\tmissing_indices=%s\tuntracked=0\toverflow=0\tfirst_workspace=2\tmonitor=2\n' \
            "$token" "$count" "$((count - 1))" "$project" > "$TMP/home/.local/state/dev-automation/desktops/terminals.ready"
          # Aguarda o backend ser realmente chamado antes de confirmar a captura.
          for _ in $(seq 1 100); do
            [[ -s "$TMP/terminal.log" ]] && break
            sleep 0.03
          done
          printf '%s\tplaced=1\texpected=1\tcomplete=1\n' "$token" > "$TMP/home/.local/state/dev-automation/desktops/terminals.result"
          ;;
        reconcile)
          printf 'reconcile\n' >> "$TMP/actions.log"
          printf '%s\taction=reconcile\tcount=%s\tmanaged=%s\tmissing=0\tmissing_indices=\tuntracked=0\toverflow=0\tfirst_workspace=2\tmonitor=2\n' \
            "$token" "$count" "$count" > "$TMP/home/.local/state/dev-automation/desktops/terminals.ready"
          printf '%s\tplaced=%s\texpected=%s\tcomplete=1\n' "$token" "$count" "$count" > "$TMP/home/.local/state/dev-automation/desktops/terminals.result"
          ;;
        *) exit 3 ;;
      esac
      if [[ "$(tail -n "$expected_actions" "$TMP/actions.log" | wc -l)" -ge "$expected_actions" ]]; then
        last_action="$(tail -n1 "$TMP/actions.log")"
        [[ "$last_action" == reconcile ]] && exit 0
      fi
      sleep 0.03
    done
    exit 2
  ) &
  WATCHER_PID=$!
}

common_env=(
  HOME="$TMP/home"
  PATH="$TMP/bin:$PATH"
  XDG_SESSION_TYPE=wayland
  XDG_CURRENT_DESKTOP=GNOME
  AUTO_CODE_STATE_DIR="$TMP/home/.local/state/dev-automation"
  PROJECTS_FILE="$TMP/projects"
  CODE_ROOT="$TMP/code"
  TERMINALS_TEST_LOG="$TMP/terminal.log"
)

# O projeto de índice 1 está ausente. Uma única chamada deve abrir SOMENTE ele
# e já reconciliar tudo, em vez da antiga fase dupla.
watch_once 1 1 3
out1="$(env "${common_env[@]}" "$ROOT/scripts/terminals.sh")"
wait "$WATCHER_PID"
[[ "$(tr '\n' ' ' < "$TMP/actions.log")" == "status open:1 reconcile " ]]
[[ "$(wc -l < "$TMP/terminal.log")" -eq 1 ]]
grep -Fq -- '--new-window --working-directory=' "$TMP/terminal.log"
grep -Fq "$TMP/code/orgs/orbital/orbital-app" "$TMP/terminal.log"
grep -Fq 'ABRINDO: orgs/orbital/orbital-app' <<<"$out1"
grep -Fq 'Idempotente:' <<<"$out1"

# Repetição: tudo existe; zero aberturas, só status + reconcile.
: > "$TMP/actions.log"
: > "$TMP/terminal.log"
rm -f "$TMP/home/.local/state/dev-automation/desktops/terminals.request" \
  "$TMP/home/.local/state/dev-automation/desktops/terminals.ready" \
  "$TMP/home/.local/state/dev-automation/desktops/terminals.result"
watch_once 0 '' 2
out2="$(env "${common_env[@]}" "$ROOT/scripts/terminals.sh")"
wait "$WATCHER_PID"
[[ "$(tr '\n' ' ' < "$TMP/actions.log")" == "status reconcile " ]]
[[ ! -s "$TMP/terminal.log" ]]
grep -Fq 'ENCONTRADOS: 5/5' <<<"$out2"

# O controlador novo precisa identificar por cwd/título e manter projeto->janela.
grep -Fq 'TERMINALS_PROJECTS_PATH' "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq 'window.get_title' "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq 'GLib.file_read_link(`/proc/${pid}/cwd`)' "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq 'detectedProject >= 0 && detectedProject !== projectIndex' "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq 'project=${projectIndex}:${sequence}' "$ROOT/apps/desktops-gnome-extension/extension.js"
grep -Fq 'missing_indices=' "$ROOT/apps/desktops-gnome-extension/extension.js"

echo 'OK: terminals abre somente o projeto ausente, reconcilia na mesma chamada e mantém identidade por pasta/projeto.'
