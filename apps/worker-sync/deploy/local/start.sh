#!/usr/bin/env bash
set -euo pipefail
systemctl --user start dev-automation-worker-to.service
systemctl --user start dev-automation-worker-from.timer
printf '[worker-sync] iniciado\n'
