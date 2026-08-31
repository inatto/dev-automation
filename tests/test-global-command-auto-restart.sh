#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/watch" "$TMP/state"
cat > "$TMP/cmd.sh" <<'EOS'
#!/usr/bin/env bash
echo run >> "$TEST_LOG"
sleep 30
EOS
chmod +x "$TMP/cmd.sh"
TEST_LOG="$TMP/log" AUTO_CODE_STATE_DIR="$TMP/state" bash "$ROOT/scripts/global-command-auto.sh" demo "$TMP/cmd.sh" "$TMP/watch" 0 >"$TMP/out" 2>&1 &
pid=$!
for _ in $(seq 1 50); do [[ -f "$TMP/log" ]] && break; sleep .1; done
[[ -f "$TMP/log" ]]
kill -USR1 "$pid"
for _ in $(seq 1 80); do [[ "$(wc -l < "$TMP/log")" -ge 2 ]] && break; sleep .1; done
[[ "$(wc -l < "$TMP/log")" -ge 2 ]]
kill -TERM "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
printf 'OK: comando global -auto reinicia após sinal de ZIP\n'
