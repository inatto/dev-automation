#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation

set -euo pipefail

# Este arquivo é chamado pelos comandos globais gerados por
# install-project-commands.sh. Normalmente não é executado diretamente.
#
# Exemplos após a instalação:
#   orbital-app              # deploy/local/start.sh
#   orbital-app start        # deploy/local/start.sh
#   orbital-app setup        # deploy/local/setup.sh
#   orbital-app run          # setup.sh + start.sh
#   orbital-app test         # deploy/local/test.sh
#   orbital-app start-api    # deploy/local/start-api.sh
#   orbital-app setup-web    # deploy/local/setup-web.sh
#   orbital-app help         # mostra ajuda e ações disponíveis

PROJECT_NAME="${1:-}"
PROJECT_DIR="${2:-}"
shift 2 || true
ACTION="${1:-start}"
if (($# > 0)); then
  shift
fi

log() {
  printf '[%s] %s\n' "$PROJECT_NAME" "$*"
}

fail() {
  printf '[%s] ERRO: %s\n' "$PROJECT_NAME" "$*" >&2
  exit 1
}

run_script() {
  local script_name="$1"
  shift || true
  local script_path="$PROJECT_DIR/deploy/local/$script_name"

  [[ -f "$script_path" ]] || fail "script local não encontrado: $script_path"

  log "diretório: $PROJECT_DIR"
  log "executando: ./deploy/local/$script_name${*:+ $*}"
  cd "$PROJECT_DIR"
  bash "$script_path" "$@"
}

show_help() {
  cat <<EOF_HELP
Uso:
  $PROJECT_NAME [ação] [argumentos]

Ações principais:
  $PROJECT_NAME              Executa deploy/local/start.sh
  $PROJECT_NAME start        Executa deploy/local/start.sh
  $PROJECT_NAME setup        Executa deploy/local/setup.sh
  $PROJECT_NAME run          Executa setup.sh e, se concluir, start.sh
  $PROJECT_NAME test         Executa deploy/local/test.sh
  $PROJECT_NAME dir          Mostra o caminho absoluto do projeto
  $PROJECT_NAME scripts      Lista scripts disponíveis em deploy/local
  $PROJECT_NAME help         Mostra esta ajuda

Também é possível chamar qualquer script existente em deploy/local sem o .sh:
  $PROJECT_NAME start-api
  $PROJECT_NAME start-web
  $PROJECT_NAME setup-api
  $PROJECT_NAME setup-web
  $PROJECT_NAME test-api
EOF_HELP
}

[[ -n "$PROJECT_NAME" ]] || fail "nome do projeto não informado"
[[ -n "$PROJECT_DIR" ]] || fail "diretório do projeto não informado"
[[ -d "$PROJECT_DIR" ]] || fail "projeto configurado não existe: $PROJECT_DIR"

case "$ACTION" in
  start)
    run_script "start.sh" "$@"
    ;;
  setup)
    run_script "setup.sh" "$@"
    ;;
  run)
    run_script "setup.sh"
    run_script "start.sh" "$@"
    ;;
  dir|path)
    printf '%s\n' "$PROJECT_DIR"
    ;;
  scripts)
    find "$PROJECT_DIR/deploy/local" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' 2>/dev/null \
      | sed 's/\.sh$//' \
      | sort
    ;;
  help|-h|--help)
    show_help
    ;;
  *)
    if [[ "$ACTION" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
      run_script "$ACTION.sh" "$@"
    else
      fail "ação inválida: $ACTION"
    fi
    ;;
esac
