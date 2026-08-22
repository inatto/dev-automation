#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
APP_DIR="$PROJECT_ROOT/apps/dev-status/linux"
BUILD_SH="$APP_DIR/build.sh"
BIN="$APP_DIR/bin/dev-status-linux"

fail() { printf '[dev-status/linux] ERRO: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  --build|build)
    exec "$BUILD_SH"
    ;;
  --help|-h|help|'')
    cat <<'HELP'
Uso:
  dev-status --build
  dev-status idle [detalhe]
  dev-status backup [detalhe]
  dev-status unzip [detalhe]
  dev-status zip [0-100] [detalhe]
  dev-status sync [0-100] [detalhe]
  dev-status clean [detalhe]
  dev-status done [detalhe]
  dev-status error [detalhe]
  dev-status paused [detalhe]
  dev-status exit
  dev-status status

Ubuntu/GNOME: indicador permanente via Ayatana AppIndicator.
HELP
    ;;
  *)
    [[ -x "$BIN" ]] || fail "executável ausente; rode: dev-status --build"
    if "$BIN" status 2>/dev/null | grep -qx ativo; then
      exec "$BIN" "$@"
    fi
    if [[ "${1:-}" == exit ]]; then
      exit 0
    fi
    nohup "$BIN" "$@" </dev/null >>"${AUTO_CODE_STATE_DIR:-$HOME/.local/state/dev-automation}/dev-status-linux.log" 2>&1 &
    disown || true
    exit 0
    ;;
esac
