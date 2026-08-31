#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/watch/scripts" "$TMP/state"

# Simula o monitor real: o primeiro dev-manager deixa um processo/lock separado.
cat > "$TMP/bin/dev-manager" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "stop" ]]; then
  exit 0
fi
if [[ -f "$TEST_LOCK" ]]; then
  echo "already-active" >> "$TEST_LOG"
  exit 3
fi
sleep 60 &
echo $! > "$TEST_LOCK"
echo run >> "$TEST_LOG"
wait
EOS
chmod +x "$TMP/bin/dev-manager"

cat > "$TMP/watch/scripts/dev-manager.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "stop" ]]; then
  if [[ -f "$TEST_LOCK" ]]; then
    pid="$(cat "$TEST_LOCK" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
    rm -f "$TEST_LOCK"
    echo stopped >> "$TEST_LOG"
  fi
fi
EOS
chmod +x "$TMP/watch/scripts/dev-manager.sh"

export PATH="$TMP/bin:$PATH"
export TEST_LOG="$TMP/log" TEST_LOCK="$TMP/lock" AUTO_CODE_STATE_DIR="$TMP/state"
bash "$ROOT/scripts/global-command-auto.sh" dev-manager dev-manager "$TMP/watch" 0 >"$TMP/out" 2>&1 &
sup=$!
for _ in $(seq 1 50); do [[ -f "$TMP/log" ]] && grep -q '^run$' "$TMP/log" && break; sleep .1; done
[[ "$(grep -c '^run$' "$TMP/log")" -eq 1 ]]
kill -USR1 "$sup"
for _ in $(seq 1 100); do [[ "$(grep -c '^run$' "$TMP/log" 2>/dev/null || true)" -ge 2 ]] && break; sleep .1; done
[[ "$(grep -c '^run$' "$TMP/log")" -ge 2 ]]
grep -q '^stopped$' "$TMP/log"
! grep -q '^already-active$' "$TMP/log"
kill -TERM "$sup" 2>/dev/null || true
wait "$sup" 2>/dev/null || true
printf 'OK: dev-manager-auto encerra monitor/lock antes de reiniciar\n'
