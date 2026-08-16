#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

grep -q 'ensure_worker_sync' "$ROOT/scripts/dev-manager.sh"
grep -q 'DEV_MANAGER_WORKER_ENSURE' "$ROOT/scripts/dev-manager.sh"
grep -q 'apps/worker-sync/deploy/local/ensure.sh' "$ROOT/scripts/dev-manager.sh"
grep -q 'systemctl --user is-active --quiet dev-automation-worker-to.service' "$ROOT/apps/worker-sync/deploy/local/ensure.sh"
grep -q 'systemctl --user is-active --quiet dev-automation-worker-from.timer' "$ROOT/apps/worker-sync/deploy/local/ensure.sh"
grep -q 'systemctl --user is-active --quiet dev-automation-worker-from-delete.service' "$ROOT/apps/worker-sync/deploy/local/ensure.sh"
grep -q 'WORKER TO:' "$ROOT/scripts/dev-manager-tui.py"
grep -q 'WORKER FROM:' "$ROOT/scripts/dev-manager-tui.py"
grep -q 'ZIPs FROM:' "$ROOT/scripts/dev-manager-tui.py"
grep -q 'TUI_WORKER_TO' "$ROOT/scripts/dev-manager/10-tui-legacy.sh"
grep -q 'TUI_WORKER_FROM' "$ROOT/scripts/dev-manager/10-tui-legacy.sh"

grep -A3 -F 'commands|refresh-commands|install-commands)' "$ROOT/scripts/dev-manager.sh" | grep -q 'ensure_worker_sync'

echo 'OK: dev-manager garante worker-sync idempotente e TUI exibe TO/FROM'
