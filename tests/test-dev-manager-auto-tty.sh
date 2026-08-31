#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/watch" "$TMP/bin"
cat > "$TMP/bin/dev-manager" <<'EOS'
#!/usr/bin/env bash
if [[ -t 0 ]]; then
  printf 'TTY_OK\n' > "$TEST_RESULT"
else
  printf 'TTY_BAD\n' > "$TEST_RESULT"
fi
trap 'exit 0' INT TERM
while :; do sleep 1; done
EOS
chmod +x "$TMP/bin/dev-manager"
export TEST_RESULT="$TMP/result"
export PATH="$TMP/bin:$PATH"
export AUTO_CODE_STATE_DIR="$TMP/state"
# `script` fornece um pseudo-terminal real para validar o contrato da TUI.
script -q -e -c "timeout 3 bash '$ROOT/scripts/global-command-auto.sh' dev-manager dev-manager '$TMP/watch' 0" /dev/null >/dev/null 2>&1 || true
[[ -f "$TMP/result" ]]
grep -Fxq 'TTY_OK' "$TMP/result"
printf 'OK dev-manager-auto preserva stdin TTY\n'
