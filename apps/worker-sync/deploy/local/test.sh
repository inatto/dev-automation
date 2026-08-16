#!/usr/bin/env bash
set -euo pipefail
APP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
bash -n "$APP_ROOT/scripts/upload-watch.sh"
bash -n "$APP_ROOT/scripts/download-from.sh"
bash -n "$APP_ROOT/deploy/local/install.sh"
bash -n "$APP_ROOT/deploy/local/start.sh"
bash -n "$APP_ROOT/deploy/local/stop.sh"
bash -n "$APP_ROOT/deploy/local/status.sh"
grep -q 'LOCAL_DIR="${WORKER_LOCAL_TO:-/home/daniel/worker/to}"' "$APP_ROOT/scripts/upload-watch.sh"
grep -q 'REMOTE_DIR="${WORKER_REMOTE_TO:-danielmaiax:worker/to}"' "$APP_ROOT/scripts/upload-watch.sh"
grep -q 'REMOTE_DIR="${WORKER_REMOTE_FROM:-danielmaiax:worker/from}"' "$APP_ROOT/scripts/download-from.sh"
grep -q 'LOCAL_DIR="${WORKER_LOCAL_FROM:-/home/daniel/worker/from}"' "$APP_ROOT/scripts/download-from.sh"
if grep -R -E 'danielmaiax:worker/from.*(/home/daniel/worker/to)|/home/daniel/worker/from.*danielmaiax:worker/from' "$APP_ROOT/scripts"; then
  echo 'ERRO: direção worker inválida encontrada' >&2
  exit 1
fi
printf '[worker-sync] testes estruturais OK\n'
