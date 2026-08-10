#!/usr/bin/env bash
# Executa o Auto Code Manager diretamente, sem sessão intermediária.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
AUTO_MANAGER="${DEV_MANAGER_AUTO_MANAGER:-$PROJECT_ROOT/scripts/auto-code-manager.sh}"
COMMAND_INSTALLER="${DEV_MANAGER_INSTALL_COMMANDS:-$PROJECT_ROOT/deploy/local/install-commands.sh}"
DESKTOPS_SCRIPT="${DEV_MANAGER_DESKTOPS_SCRIPT:-$PROJECT_ROOT/scripts/desktops.sh}"
DEV_STATUS_SCRIPT="${DEV_MANAGER_DEV_STATUS_SCRIPT:-$PROJECT_ROOT/scripts/dev-status.sh}"
DEV_STATUS_EXE="${DEV_MANAGER_DEV_STATUS_EXE:-$PROJECT_ROOT/apps/dev-status/bin/dev-status.exe}"

fail() {
  printf '[dev-manager] ERRO: %s\n' "$*" >&2
  exit 1
}

show_help() {
  cat <<'EOF_HELP'
Uso:
  dev-manager              Inicia o monitor em primeiro plano
  dev-manager start        Mesmo comportamento acima
  dev-manager --test-sound Testa o aviso sonoro
  dev-manager --test-backup-sound Testa o aviso sutil de backup
  dev-manager commands     Atualiza todos os comandos globais
  dev-manager desktops     Cria/nomeia desktops pelos projetos ativos
  dev-manager status       Verifica se há um monitor ativo
  dev-manager stop         Explica como encerrar o monitor ativo
  dev-manager help         Mostra esta ajuda

O monitor não cria sessão em segundo plano. Para encerrar, pressione Ctrl+C
no mesmo terminal em que ele está executando.
EOF_HELP
}

refresh_global_commands() {
  [[ -f "$COMMAND_INSTALLER" ]] || fail "instalador de comandos não encontrado: $COMMAND_INSTALLER"
  [[ -x "$COMMAND_INSTALLER" ]] || chmod +x "$COMMAND_INSTALLER"

  printf '[dev-manager] atualizando todos os comandos globais antes de iniciar...\n'
  "$COMMAND_INSTALLER"
  hash -r 2>/dev/null || true
  printf '[dev-manager] comandos globais atualizados.\n'
}

ensure_dev_status() {
  [[ -f "$DEV_STATUS_EXE" ]] && return 0

  if [[ ! -f "$DEV_STATUS_SCRIPT" ]]; then
    printf '[dev-manager] AVISO: dev-status ausente; seguindo sem indicador da taskbar.\n' >&2
    return 0
  fi

  [[ -x "$DEV_STATUS_SCRIPT" ]] || chmod +x "$DEV_STATUS_SCRIPT"

  printf '[dev-manager] dev-status.exe ausente; compilando uma vez...\n'
  if "$DEV_STATUS_SCRIPT" --build; then
    if [[ -f "$DEV_STATUS_EXE" ]]; then
      printf '[dev-manager] dev-status pronto.\n'
      return 0
    fi
  fi

  printf '[dev-manager] AVISO: não foi possível compilar dev-status; seguindo sem indicador da taskbar.\n' >&2
  return 0
}

status_manager() {
  local matches
  matches="$(pgrep -af '[a]uto-code-manager\.sh' || true)"
  if [[ -n "$matches" ]]; then
    printf '[dev-manager] monitor ativo:\n%s\n' "$matches"
  else
    printf '[dev-manager] nenhum monitor ativo.\n'
  fi
}

[[ -f "$AUTO_MANAGER" ]] || fail "script não encontrado: $AUTO_MANAGER"
[[ -x "$AUTO_MANAGER" ]] || chmod +x "$AUTO_MANAGER"

action="${1:-start}"
case "$action" in
  start|run)
    shift || true
    refresh_global_commands
    ensure_dev_status
    printf '[dev-manager] executando em primeiro plano; para parar, pressione Ctrl+C.\n'
    exec "$AUTO_MANAGER" "$@"
    ;;
  --test-sound|test-sound)
    exec "$AUTO_MANAGER" --test-sound
    ;;
  --test-backup-sound|test-backup-sound)
    exec "$AUTO_MANAGER" --test-backup-sound
    ;;
  commands|refresh-commands|install-commands)
    refresh_global_commands
    ;;
  desktops)
    shift || true
    [[ -f "$DESKTOPS_SCRIPT" ]] || fail "script de desktops não encontrado: $DESKTOPS_SCRIPT"
    [[ -x "$DESKTOPS_SCRIPT" ]] || chmod +x "$DESKTOPS_SCRIPT"
    exec "$DESKTOPS_SCRIPT" "$@"
    ;;
  status)
    status_manager
    ;;
  stop)
    printf '[dev-manager] não há sessão em segundo plano para encerrar.\n'
    printf '[dev-manager] pressione Ctrl+C no terminal em que o monitor está rodando.\n'
    ;;
  attach|restart)
    fail "a ação '$action' foi removida porque o monitor agora roda em primeiro plano. Use 'dev-manager' e encerre com Ctrl+C."
    ;;
  help|-h|--help)
    show_help
    ;;
  *)
    fail "ação inválida: $action (use 'dev-manager help')"
    ;;
esac
