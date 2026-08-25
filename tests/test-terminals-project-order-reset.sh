#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/terminals-order-test-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.local/state/dev-automation/desktops" "$TMP/code/a" "$TMP/code/b"
printf 'a\nb\n' > "$TMP/projects"

cat > "$TMP/bin/gnome-shell" <<'FAKE'
#!/usr/bin/env bash
printf 'GNOME Shell 50.1\n'
FAKE
cat > "$TMP/bin/gnome-extensions" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" == info ]] && { printf '  Version: 13\n  State: ACTIVE\n'; exit 0; }
exit 0
FAKE
cat > "$TMP/bin/ptyxis" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$TMP/bin/"*
cat > "$TMP/home/.local/state/dev-automation/desktops/extension.ready" <<'READY'
version=13
controller=1
floating-label=0
window-placement=1
READY
printf 'assinatura-antiga\n' > "$TMP/home/.local/state/dev-automation/desktops/terminals.projects.sha256"
printf 'shell=999\nmanaged=123\n' > "$TMP/home/.local/state/dev-automation/desktops/terminals.batch"
: > "$TMP/actions.log"

run_controller() {
  (
    last=''
    seen=0
    deadline=$((SECONDS + 20))
    while (( SECONDS < deadline )); do
      req="$TMP/home/.local/state/dev-automation/desktops/terminals.request"
      [[ -s "$req" ]] || { sleep 0.03; continue; }
      line="$(cat "$req")"; token="${line%%$'\t'*}"
      [[ "$token" != "$last" ]] || { sleep 0.03; continue; }
      last="$token"
      action="$(tr '\t' '\n' <<<"$line" | sed -n 's/^action=//p' | head -n1)"
      count="$(tr '\t' '\n' <<<"$line" | sed -n 's/^count=//p' | head -n1)"
      printf '%s\n' "$action" >> "$TMP/actions.log"
      case "$action" in
        status|reconcile)
          printf '%s\taction=%s\tcount=%s\tmanaged=%s\tmissing=0\tmissing_indices=\tuntracked=0\toverflow=0\tfirst_workspace=2\tmonitor=2\n' \
            "$token" "$action" "$count" "$count" > "$TMP/home/.local/state/dev-automation/desktops/terminals.ready"
          printf '%s\tplaced=%s\texpected=%s\tcomplete=1\n' "$token" "$count" "$count" > "$TMP/home/.local/state/dev-automation/desktops/terminals.result"
          ;;
        *) exit 4 ;;
      esac
      seen=$((seen + 1))
      (( seen >= 2 )) && exit 0
    done
    exit 5
  ) &
  controller=$!
}

common_env=(
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME
  AUTO_CODE_STATE_DIR="$TMP/home/.local/state/dev-automation" PROJECTS_FILE="$TMP/projects" CODE_ROOT="$TMP/code"
)

run_controller
env "${common_env[@]}" "$ROOT/scripts/terminals.sh" >/dev/null
wait "$controller"
[[ "$(tr '\n' ' ' < "$TMP/actions.log")" == 'status reconcile ' ]]
[[ -s "$TMP/home/.local/state/dev-automation/desktops/terminals.projects.tsv" ]]
grep -Fq $'0\ta\t' "$TMP/home/.local/state/dev-automation/desktops/terminals.projects.tsv"

# Reordena. Não deve mais fechar/reabrir o lote: a identidade vem da pasta.
printf 'b\na\n' > "$TMP/projects"
: > "$TMP/actions.log"
rm -f "$TMP/home/.local/state/dev-automation/desktops/terminals.request" \
  "$TMP/home/.local/state/dev-automation/desktops/terminals.ready" \
  "$TMP/home/.local/state/dev-automation/desktops/terminals.result"
run_controller
env "${common_env[@]}" "$ROOT/scripts/terminals.sh" >/dev/null
wait "$controller"
[[ "$(tr '\n' ' ' < "$TMP/actions.log")" == 'status reconcile ' ]]
! grep -Fq 'managed-reset' "$TMP/actions.log"
first_name="$(awk -F '\t' '$1==0 {print $2}' "$TMP/home/.local/state/dev-automation/desktops/terminals.projects.tsv")"
[[ "$first_name" == b ]]
! grep -Fxq 'assinatura-antiga' "$TMP/home/.local/state/dev-automation/desktops/terminals.projects.sha256"

echo 'OK: reordenação de projetos atualiza identidade por pasta e não destrói/reabre terminais existentes.'
