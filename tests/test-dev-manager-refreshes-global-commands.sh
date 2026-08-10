#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d /tmp/dev-manager-refresh-test-XXXXXX)"
LOG_FILE="$TEMP_ROOT/order.log"
FAKE_INSTALLER="$TEMP_ROOT/install-commands.sh"
FAKE_MANAGER="$TEMP_ROOT/auto-code-manager.sh"
FAKE_STATUS_EXE="$TEMP_ROOT/dev-status.exe"
FAKE_STATUS_SOURCE="$TEMP_ROOT/main.cpp"
FAKE_STATUS_BUILD="$TEMP_ROOT/build.ps1"

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

printf 'exe
' > "$FAKE_STATUS_EXE"
printf 'source
' > "$FAKE_STATUS_SOURCE"
printf 'build
' > "$FAKE_STATUS_BUILD"
touch -t 202601010000 "$FAKE_STATUS_SOURCE" "$FAKE_STATUS_BUILD"
touch -t 202601010001 "$FAKE_STATUS_EXE"

chmod +x "$FAKE_INSTALLER" "$FAKE_MANAGER"

TEST_ORDER_LOG="$LOG_FILE" \
DEV_MANAGER_INSTALL_COMMANDS="$FAKE_INSTALLER" \
DEV_MANAGER_AUTO_MANAGER="$FAKE_MANAGER" \
DEV_MANAGER_DEV_STATUS_EXE="$FAKE_STATUS_EXE" \
DEV_MANAGER_DEV_STATUS_SOURCE="$FAKE_STATUS_SOURCE" \
DEV_MANAGER_DEV_STATUS_BUILD_PS1="$FAKE_STATUS_BUILD" \
  "$PROJECT_ROOT/scripts/dev-manager.sh" start --probe

mapfile -t lines < "$LOG_FILE"
[ "${#lines[@]}" -eq 2 ]
[ "${lines[0]}" = 'installer' ]
[ "${lines[1]}" = 'manager:--probe' ]

printf 'OK: dev-manager atualiza os comandos globais antes de iniciar o monitor\n'
