#!/usr/bin/env bash
set -euo pipefail
systemctl --user stop dev-automation-worker-to.service 2>/dev/null || true
systemctl --user stop dev-automation-worker-from.timer 2>/dev/null || true
systemctl --user stop dev-automation-worker-from.service 2>/dev/null || true
systemctl --user stop dev-automation-worker-from-delete.service 2>/dev/null || true
printf '[worker-sync] parado\n'
