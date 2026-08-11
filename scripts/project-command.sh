#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CLEAR_TERMINAL="$SCRIPT_DIR/clear-terminal.sh"

PROJECT_NAME="${1:-}"
PROJECT_DIR="${2:-}"
DEPLOY_MODE="${3:-local}"
shift 3 || true
ACTION="${1:-setup}"
if (($# > 0)); then
  shift
fi

[[ -f "$CLEAR_TERMINAL" ]] && bash "$CLEAR_TERMINAL"

fail() {
  printf '[%s] ERRO: %s\n' "$PROJECT_NAME" "$*" >&2
  exit 1
}

[[ -n "$PROJECT_NAME" ]] || fail "nome do projeto não informado"
[[ -n "$PROJECT_DIR" ]] || fail "diretório do projeto não informado"
[[ "$DEPLOY_MODE" == "local" || "$DEPLOY_MODE" == "remote" ]] || fail "modo de deploy inválido: $DEPLOY_MODE"
[[ -d "$PROJECT_DIR" ]] || fail "projeto configurado não existe: $PROJECT_DIR"
[[ "$ACTION" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || fail "ação inválida: $ACTION"

SCRIPT_PATH="$PROJECT_DIR/deploy/$DEPLOY_MODE/$ACTION.sh"
[[ -f "$SCRIPT_PATH" ]] || fail "script não encontrado: $SCRIPT_PATH"

printf '[%s] executando: ./deploy/%s/%s.sh%s\n' \
  "$PROJECT_NAME" "$DEPLOY_MODE" "$ACTION" "${*:+ $*}"
cd "$PROJECT_DIR"
exec bash "$SCRIPT_PATH" "$@"
