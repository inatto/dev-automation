#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/files-wayland-test-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state/desktops" "$TMP/code"
cat > "$TMP/bin/nautilus" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FILES_TEST_LOG"
FAKE
cat > "$TMP/bin/gnome-shell" <<'FAKE'
#!/usr/bin/env bash
printf 'GNOME Shell 50.1\n'
FAKE
cat > "$TMP/bin/gnome-extensions" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  info) printf '  Version: 11\n  State: ACTIVE\n' ;;
esac
FAKE
chmod +x "$TMP/bin/"*
cat > "$TMP/state/desktops/extension.ready" <<'READY'
version=13
controller=1
floating-label=0
window-placement=1
READY
: > "$TMP/files.log"
(
  req="$TMP/state/desktops/chromes.request"
  for _ in $(seq 1 120); do
    if [[ -s "$req" ]]; then
      request="$(cat "$req")"
      printf '%s\n' "$request" > "$TMP/request.log"
      IFS=$'\t' read -r token _ <<< "$request"
      printf '%s\tworkspace=5\tmonitor=0\tmaximize=1\n' "$token" > "$TMP/state/desktops/chromes.ready"
      for _ in $(seq 1 120); do
        if [[ -s "$TMP/files.log" ]]; then
          printf '%s\tbrowsers=0\tnautilus=1\n' "$token" > "$TMP/state/desktops/chromes.result"
          exit 0
        fi
        sleep 0.05
      done
      exit 2
    fi
    sleep 0.05
  done
  exit 1
) & watcher=$!
out="$(HOME="$TMP/home" PATH="$TMP/bin:$PATH" XDG_SESSION_TYPE=wayland AUTO_CODE_STATE_DIR="$TMP/state" FILES_TEST_LOG="$TMP/files.log" FILES_DIR="$TMP/code" FILES_TARGET_WORKSPACE=5 "$ROOT/scripts/files/ubuntu.sh")"
wait "$watcher"
grep -Fq $'action=default\tworkspace=5\tmaximize=1' "$TMP/request.log"
grep -Fqx -- "--new-window $TMP/code" "$TMP/files.log"
grep -Fq 'Destino: workspace 5, monitor mais à esquerda, maximizado.' <<< "$out"
grep -Fq 'Files confirmado no workspace 5 / monitor esquerdo.' <<< "$out"
echo 'OK: files abre /home/daniel/Code-equivalente no workspace alvo, monitor esquerdo e maximizado.'
