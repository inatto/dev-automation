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
