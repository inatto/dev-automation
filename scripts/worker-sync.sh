#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
LOCAL_DIR="$PROJECT_ROOT/apps/worker-sync/deploy/local"

usage() {
  cat <<'TXT'
Uso: worker-sync <comando>

  install   instala/reinstala os units systemd e para configuração antiga
  start     inicia upload por evento + download remoto por timer
  stop      para os dois fluxos
  restart   reinstala e reinicia a configuração do dev-automation
  status    mostra status systemd
  test      valida scripts e direções
  logs      acompanha os logs dos dois fluxos
TXT
}

cmd="${1:-status}"
case "$cmd" in
  install) exec "$LOCAL_DIR/install.sh" ;;
  start) exec "$LOCAL_DIR/start.sh" ;;
  stop) exec "$LOCAL_DIR/stop.sh" ;;
  restart)
    "$LOCAL_DIR/stop.sh"
    "$LOCAL_DIR/install.sh"
    exec "$LOCAL_DIR/start.sh"
    ;;
  status) exec "$LOCAL_DIR/status.sh" ;;
  test) exec "$LOCAL_DIR/test.sh" ;;
  logs)
    exec journalctl --user \
      -u dev-automation-worker-to.service \
      -u dev-automation-worker-from.service \
      -f
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
