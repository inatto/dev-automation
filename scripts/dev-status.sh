#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
APP_DIR="$PROJECT_ROOT/apps/dev-status"
BUILD_PS1="$APP_DIR/build.ps1"
INVOKE_PS1="$APP_DIR/invoke.ps1"
EXE="$APP_DIR/bin/dev-status.exe"

fail() { printf '[dev-status] ERRO: %s\n' "$*" >&2; exit 1; }

windows_path() {
  command -v wslpath >/dev/null 2>&1 || fail 'wslpath não encontrado; este comando deve rodar no WSL.'
  wslpath -w "$1"
}

command -v powershell.exe >/dev/null 2>&1 || fail 'powershell.exe não encontrado via interoperabilidade WSL.'

case "${1:-}" in
  --build|build)
    exec powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(windows_path "$BUILD_PS1")"
    ;;
  --help|-h|help|'')
    cat <<'EOF'
Uso:
  dev-status --build
  dev-status idle
  dev-status backup
  dev-status unzip
  dev-status zip [0-100]
  dev-status sync [0-100]
  dev-status clean
  dev-status done
  dev-status error
  dev-status exit
EOF
    ;;
  *)
    [[ -f "$EXE" ]] || fail "executável ausente; rode: dev-status --build"
    state="$1"
    shift
    progress=-1
    detail=''
    if [[ "${1:-}" =~ ^([0-9]|[1-9][0-9]|100)$ ]]; then
      progress="$1"
      shift
    fi
    if [[ $# -gt 0 ]]; then
      detail="$*"
    fi
    exec powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -File "$(windows_path "$INVOKE_PS1")" -State "$state" -Progress "$progress" -Detail "$detail"
    ;;
esac
