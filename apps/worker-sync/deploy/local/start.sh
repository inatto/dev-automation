#!/usr/bin/env bash
set -euo pipefail
systemctl --user start dev-automation-worker-to.service
systemctl --user start dev-automation-worker-from.timer
systemctl --user start dev-automation-worker-from-delete.service
printf '[worker-sync] iniciado\n'
