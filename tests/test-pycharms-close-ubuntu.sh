#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/pycharms-close-ubuntu-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state/pycharms"
cat > "$TMP/bin/gnome-shell" <<'EOF'
#!/usr/bin/env bash
printf 'GNOME Shell 50.1\n'
EOF
cat > "$TMP/bin/gnome-extensions" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/"*
(
  for _ in $(seq 1 100); do
    req="$TMP/state/pycharms/close.request"
    if [[ -s "$req" ]]; then
      token="$(cat "$req")"
      printf 'solicitadas=3 ignoradas=0\n' > "$TMP/state/pycharms/close.result"
      printf '%s\n' "$token" > "$TMP/state/pycharms/close.ready"
      exit 0
    fi
    sleep 0.05
  done
  exit 1
) &
watcher=$!
out="$(PATH="$TMP/bin:$PATH" HOME="$TMP/home" AUTO_CODE_STATE_DIR="$TMP/state" XDG_SESSION_TYPE=wayland PYCHARMS_PLATFORM=ubuntu "$ROOT/scripts/pycharms.sh" --close)"
wait "$watcher"
grep -Fq 'fechamento solicitado para todas as janelas PyCharm' <<<"$out"
grep -Fq 'solicitadas=3' <<<"$out"
echo 'OK: pycharms --close envia pedido GNOME e aguarda confirmação sem kill forçado.'
