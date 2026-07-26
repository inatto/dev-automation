#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d /tmp/dev-manager-refresh-test-XXXXXX)"
LOG_FILE="$TEMP_ROOT/order.log"
FAKE_INSTALLER="$TEMP_ROOT/install-commands.sh"
FAKE_MANAGER="$TEMP_ROOT/auto-code-manager.sh"

cleanup() {
  rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT

cat > "$FAKE_INSTALLER" <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
printf 'installer\n' >> "${TEST_ORDER_LOG:?}"
INSTALLER

cat > "$FAKE_MANAGER" <<'MANAGER'
#!/usr/bin/env bash
set -euo pipefail
printf 'manager:%s\n' "$*" >> "${TEST_ORDER_LOG:?}"
MANAGER

chmod +x "$FAKE_INSTALLER" "$FAKE_MANAGER"

TEST_ORDER_LOG="$LOG_FILE" \
DEV_MANAGER_INSTALL_COMMANDS="$FAKE_INSTALLER" \
DEV_MANAGER_AUTO_MANAGER="$FAKE_MANAGER" \
  "$PROJECT_ROOT/scripts/dev-manager.sh" start --probe

mapfile -t lines < "$LOG_FILE"
[ "${#lines[@]}" -eq 2 ]
[ "${lines[0]}" = 'installer' ]
[ "${lines[1]}" = 'manager:--probe' ]

printf 'OK: dev-manager atualiza os comandos globais antes de iniciar o monitor\n'
