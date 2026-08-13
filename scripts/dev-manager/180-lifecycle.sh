#!/usr/bin/env bash
# Contexto: encerramento limpo do manager

stop() {
  stop_backup_watcher
  if [ "$PAUSE_CONTROL_ACTIVE" = true ]; then
    rm -f -- "$PAUSE_FILE"
  fi
  taskbar_status exit "Auto Code Manager encerrado"
  if [ "$TUI_ACTIVE" = true ]; then
    LOG_CONTEXT=wait log "Encerrando interface Clipper..."
    tui_cleanup
  fi
  echo
  line
  echo "Encerrado. Log da sessão: $TUI_LOG_FILE"
  exit 0
}

