#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LOCAL="$HERE/deploy/local"
API_VENV="$HERE/apps/api/.venv/bin/python"
WEB_MODULES="$HERE/apps/web/node_modules"

command="${1:-}"

case "$command" in
  --setup)
    exec "$LOCAL/setup.sh"
    ;;
  --doctor|--test)
    exec "$LOCAL/test.sh"
    ;;
  --api)
    exec "$LOCAL/start-api.sh"
    ;;
  --web)
    exec "$LOCAL/start-web.sh"
    ;;
  ""|--start)
    if [[ ! -x "$API_VENV" || ! -d "$WEB_MODULES" ]]; then
      echo "[amazon-imap-bot] ambiente Web/API ainda não preparado; executando setup local..."
      exec "$LOCAL/setup.sh"
    fi
    echo "[amazon-imap-bot] iniciando Web + API..."
    exec "$LOCAL/start.sh"
    ;;
  *)
    echo "Uso: amazon-imap-bot [--start|--setup|--doctor|--test|--api|--web]" >&2
    exit 2
    ;;
esac
