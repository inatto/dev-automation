#!/usr/bin/env bash
set -euo pipefail
systemctl --user status dev-automation-worker-to.service dev-automation-worker-from.timer dev-automation-worker-from-delete.service --no-pager || true
