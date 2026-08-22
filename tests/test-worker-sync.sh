#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
"$ROOT/apps/worker-sync/deploy/local/test.sh"
grep -q 'worker-sync' "$ROOT/deploy/local/install-commands.sh"
grep -q 'dev-automation-worker-to.service' "$ROOT/apps/worker-sync/deploy/local/install.sh"
grep -q 'dev-automation-worker-from.timer' "$ROOT/apps/worker-sync/deploy/local/install.sh"
grep -q 'dev-automation-worker-from-delete.service' "$ROOT/apps/worker-sync/deploy/local/install.sh"
echo '[test-worker-sync] OK'
