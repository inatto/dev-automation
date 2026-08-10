#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d /tmp/dev-manager-stale-status-test-XXXXXX)"
LOG_FILE="$TEMP_ROOT/order.log"
FAKE_INSTALLER="$TEMP_ROOT/install-commands.sh"
FAKE_MANAGER="$TEMP_ROOT/auto-code-manager.sh"
FAKE_STATUS="$TEMP_ROOT/dev-status.sh"
FAKE_EXE="$TEMP_ROOT/dev-status.exe"
FAKE_SOURCE="$TEMP_ROOT/main.cpp"
FAKE_BUILD="$TEMP_ROOT/build.ps1"

cleanup() { rm -rf -- "$TEMP_ROOT"; }
trap cleanup EXIT

cat > "$FAKE_INSTALLER" <<'EOF'
#!/usr/bin/env bash
printf 'installer\n' >> "${TEST_ORDER_LOG:?}"
EOF
cat > "$FAKE_MANAGER" <<'EOF'
#!/usr/bin/env bash
printf 'manager\n' >> "${TEST_ORDER_LOG:?}"
EOF
cat > "$FAKE_STATUS" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = '--build' ] || exit 2
printf 'build\n' >> "${TEST_ORDER_LOG:?}"
touch "${TEST_DEV_STATUS_EXE:?}"
EOF

printf 'old\n' > "$FAKE_EXE"
printf 'source\n' > "$FAKE_SOURCE"
printf 'build\n' > "$FAKE_BUILD"
touch -t 202601010000 "$FAKE_EXE"
touch -t 202601010001 "$FAKE_SOURCE" "$FAKE_BUILD"
chmod +x "$FAKE_INSTALLER" "$FAKE_MANAGER" "$FAKE_STATUS"

TEST_ORDER_LOG="$LOG_FILE" \
TEST_DEV_STATUS_EXE="$FAKE_EXE" \
DEV_MANAGER_INSTALL_COMMANDS="$FAKE_INSTALLER" \
DEV_MANAGER_AUTO_MANAGER="$FAKE_MANAGER" \
DEV_MANAGER_DEV_STATUS_SCRIPT="$FAKE_STATUS" \
DEV_MANAGER_DEV_STATUS_EXE="$FAKE_EXE" \
DEV_MANAGER_DEV_STATUS_SOURCE="$FAKE_SOURCE" \
DEV_MANAGER_DEV_STATUS_BUILD_PS1="$FAKE_BUILD" \
  "$PROJECT_ROOT/scripts/dev-manager.sh" start

mapfile -t lines < "$LOG_FILE"
[ "${#lines[@]}" -eq 3 ]
[ "${lines[0]}" = 'installer' ]
[ "${lines[1]}" = 'build' ]
[ "${lines[2]}" = 'manager' ]

printf 'OK: dev-manager recompila dev-status quando o fonte é mais novo que o exe\n'
