#!/usr/bin/env bash
# Executa o Auto Code Manager diretamente, sem sessão intermediária.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
AUTO_MANAGER="${DEV_MANAGER_AUTO_MANAGER:-$PROJECT_ROOT/scripts/auto-code-manager.sh}"
COMMAND_INSTALLER="${DEV_MANAGER_INSTALL_COMMANDS:-$PROJECT_ROOT/deploy/local/install-commands.sh}"
DESKTOPS_SCRIPT="${DEV_MANAGER_DESKTOPS_SCRIPT:-$PROJECT_ROOT/scripts/desktops.sh}"
DEV_STATUS_SCRIPT="${DEV_MANAGER_DEV_STATUS_SCRIPT:-$PROJECT_ROOT/scripts/dev-status.sh}"
WORKER_ENSURE_SCRIPT="${DEV_MANAGER_WORKER_ENSURE:-$PROJECT_ROOT/apps/worker-sync/deploy/local/ensure.sh}"
if command -v powershell.exe >/dev/null 2>&1; then
  DEV_STATUS_BINARY="${DEV_MANAGER_DEV_STATUS_EXE:-$PROJECT_ROOT/apps/dev-status/bin/dev-status.exe}"
  DEV_STATUS_SOURCE="${DEV_MANAGER_DEV_STATUS_SOURCE:-$PROJECT_ROOT/apps/dev-status/src/main.cpp}"
  DEV_STATUS_BUILD_FILE="${DEV_MANAGER_DEV_STATUS_BUILD_PS1:-$PROJECT_ROOT/apps/dev-status/build.ps1}"
  DEV_STATUS_LABEL="dev-status.exe"
else
  DEV_STATUS_BINARY="${DEV_MANAGER_DEV_STATUS_BINARY:-${DEV_MANAGER_DEV_STATUS_EXE:-$PROJECT_ROOT/apps/dev-status/linux/bin/dev-status-linux}}"
  DEV_STATUS_SOURCE="${DEV_MANAGER_DEV_STATUS_SOURCE:-$PROJECT_ROOT/apps/dev-status/linux/src/main.cpp}"
  DEV_STATUS_BUILD_FILE="${DEV_MANAGER_DEV_STATUS_BUILD_FILE:-${DEV_MANAGER_DEV_STATUS_BUILD_PS1:-$PROJECT_ROOT/apps/dev-status/linux/build.sh}}"
  DEV_STATUS_LABEL="${DEV_MANAGER_DEV_STATUS_EXE:+dev-status.exe}"
  DEV_STATUS_LABEL="${DEV_STATUS_LABEL:-dev-status-linux}"
fi

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
Para pausar/despausar sem encerrar, use o menu do ícone Dev Automation
no Windows ou no painel do Ubuntu/GNOME.
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

dev_status_needs_build() {
  [[ -f "$DEV_STATUS_BINARY" ]] || return 0
  [[ -f "$DEV_STATUS_SOURCE" && "$DEV_STATUS_SOURCE" -nt "$DEV_STATUS_BINARY" ]] && return 0
  [[ -f "$DEV_STATUS_BUILD_FILE" && "$DEV_STATUS_BUILD_FILE" -nt "$DEV_STATUS_BINARY" ]] && return 0
  return 1
}

ensure_worker_sync() {
  if [[ ! -f "$WORKER_ENSURE_SCRIPT" ]]; then
    printf '[dev-manager] AVISO: worker-sync ensure ausente: %s\n' "$WORKER_ENSURE_SCRIPT" >&2
    return 0
  fi

  [[ -x "$WORKER_ENSURE_SCRIPT" ]] || chmod +x "$WORKER_ENSURE_SCRIPT"
  printf '[dev-manager] garantindo workers TO/FROM...\n'
  if "$WORKER_ENSURE_SCRIPT"; then
    printf '[dev-manager] workers TO/FROM OK.\n'
  else
    # O monitor continua abrindo para mostrar o estado na TUI; não derruba o terminal.
    printf '[dev-manager] AVISO: worker-sync não ficou 100%% ativo; confira o indicador na TUI.\n' >&2
  fi
  return 0
}

ensure_dev_status() {
  if ! dev_status_needs_build; then
    return 0
  fi

  if [[ ! -f "$DEV_STATUS_SCRIPT" ]]; then
    printf '[dev-manager] AVISO: dev-status ausente; seguindo sem indicador no system tray.\n' >&2
    return 0
  fi

  [[ -x "$DEV_STATUS_SCRIPT" ]] || chmod +x "$DEV_STATUS_SCRIPT"

  if [[ -f "$DEV_STATUS_BINARY" ]]; then
    printf '[dev-manager] %s desatualizado; recompilando...\n' "$DEV_STATUS_LABEL"
  else
    printf '[dev-manager] %s ausente; compilando uma vez...\n' "$DEV_STATUS_LABEL"
  fi

  if "$DEV_STATUS_SCRIPT" --build; then
    if [[ -f "$DEV_STATUS_BINARY" ]] && ! dev_status_needs_build; then
      printf '[dev-manager] dev-status pronto.\n'
      return 0
    fi
  fi

  printf '[dev-manager] AVISO: não foi possível compilar dev-status; seguindo sem indicador no system tray.\n' >&2
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
    ensure_worker_sync
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
    ensure_worker_sync
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
