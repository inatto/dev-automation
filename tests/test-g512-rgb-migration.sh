#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d /tmp/g512-rgb-test-XXXXXX)"
HOME_DIR="$TEMP_ROOT/home"
UNIT_DIR="$HOME_DIR/.config/systemd/user"
LEGACY_DIR="$HOME_DIR/Code/playground/g512"
STATE_DIR="$HOME_DIR/.local/state/dev-automation/g512"
APP_DIR="$TEMP_ROOT/incorporated"
FAKE_BIN="$TEMP_ROOT/bin"
LOG_FILE="$TEMP_ROOT/systemctl.log"

cleanup() { rm -rf -- "$TEMP_ROOT"; }
trap cleanup EXIT

mkdir -p "$UNIT_DIR" "$LEGACY_DIR" "$FAKE_BIN"
cat > "$LEGACY_DIR/keyboard_rgb.py" <<'PY'
from helper import VALUE
print(VALUE)
PY
cat > "$LEGACY_DIR/helper.py" <<'PY'
VALUE = 'g512'
PY
cat > "$UNIT_DIR/g512-rgb.service" <<EOF_UNIT
[Service]
WorkingDirectory=$LEGACY_DIR
ExecStart=$HOME_DIR/Code/playground/.venv/bin/python keyboard_rgb.py
Restart=always
RestartSec=2
EOF_UNIT

cat > "$FAKE_BIN/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_SYSTEMCTL_LOG:?}"
args=("$@")
if [[ " ${args[*]} " == *" show "* && " ${args[*]} " == *" FragmentPath "* ]]; then
  printf '%s\n' "${TEST_LEGACY_UNIT:?}"
  exit 0
fi
exit 0
SH
chmod +x "$FAKE_BIN/systemctl"

HOME="$HOME_DIR" \
PATH="$FAKE_BIN:$PATH" \
TEST_SYSTEMCTL_LOG="$LOG_FILE" \
TEST_LEGACY_UNIT="$UNIT_DIR/g512-rgb.service" \
G512_SYSTEMCTL="$FAKE_BIN/systemctl" \
G512_USER_UNIT_DIR="$UNIT_DIR" \
G512_STATE_DIR="$STATE_DIR" \
G512_APP_DIR="$APP_DIR" \
G512_SKIP_HARDWARE_CHECK=1 \
  "$PROJECT_ROOT/scripts/g512-rgb.sh" ensure

[ -f "$APP_DIR/keyboard_rgb.py" ]
[ -f "$APP_DIR/helper.py" ]
[ "$(cat "$APP_DIR/.main-script")" = 'keyboard_rgb.py' ]
[ -f "$UNIT_DIR/dev-automation-g512-rgb.service" ]
[ ! -f "$UNIT_DIR/g512-rgb.service" ]
grep -Fq 'RestartSec=5' "$UNIT_DIR/dev-automation-g512-rgb.service"
grep -Fq 'StartLimitBurst=5' "$UNIT_DIR/dev-automation-g512-rgb.service"
grep -Fq -- '--user disable --now g512-rgb.service' "$LOG_FILE"
grep -Fq -- '--user restart dev-automation-g512-rgb.service' "$LOG_FILE"

printf 'OK: G512 legado migra para dev-automation, troca a unit e limita reinícios\n'
