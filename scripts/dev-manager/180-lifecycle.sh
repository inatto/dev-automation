#!/usr/bin/env bash
# Contexto: encerramento limpo do manager

manager_exit_cleanup() {
  # EXIT também cobre falhas depois que o flock foi adquirido. A liberação só
  # remove o arquivo quando ESTA instância é realmente dona do lock.
  stop_backup_watcher || true
  if [ "${PAUSE_CONTROL_ACTIVE:-false}" = true ]; then
    rm -f -- "$PAUSE_FILE"
  fi
  release_monitor_lock
  tui_cleanup
}

stop() {
  # Evita reentrância se INT/TERM chegar durante a própria finalização.
  trap - INT TERM
  taskbar_status exit "Auto Code Manager encerrado"
  if [ "$TUI_ACTIVE" = true ]; then
    LOG_CONTEXT=wait log "Encerrando interface Clipper..."
  fi
  echo
  line
  echo "Encerrado. Log da sessão: $TUI_LOG_FILE"
  exit 0
}

restart_dev_manager_if_requested() {
  [ "${DEV_MANAGER_RESTART_REQUESTED:-false}" = true ] || return 0
  DEV_MANAGER_RESTART_REQUESTED=false

  taskbar_status wait "Reiniciando Dev Manager"
  LOG_CONTEXT=wait log "DEV MANAGER: atualização do Dev Automation confirmada; reiniciando para carregar a nova versão."

  stop_backup_watcher || true
  if [ "${PAUSE_CONTROL_ACTIVE:-false}" = true ]; then
    rm -f -- "$PAUSE_FILE"
    PAUSE_CONTROL_ACTIVE=false
  fi
  release_monitor_lock
  tui_cleanup

  # O processo continua no mesmo terminal (inclusive como filho da TUI), mas
  # volta pelo launcher atualizado para reparar comandos e carregar os módulos novos.
  trap - EXIT INT TERM WINCH
  exec bash "$PROJECT_ROOT/scripts/dev-manager.sh" start
}

