#!/usr/bin/env bash
set -euo pipefail
systemctl --user status dev-automation-worker-to.service dev-automation-worker-from.timer --no-pager || true
