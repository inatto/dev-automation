#!/usr/bin/env bash
# Contexto: traps, comandos one-shot, inicialização e loop principal

trap stop INT TERM
trap tui_cleanup EXIT
trap tui_on_resize WINCH

ensure_files
load_env
ensure_worker_dirs
validate_timers

if [ "${1:-}" = "--test-sound" ]; then
  soft_beep
  exit $?
fi

if [ "${1:-}" = "--test-backup-sound" ]; then
  backup_beep
  exit $?
fi

if [ "${1:-}" = "--error-sound" ] || [ "${1:-}" = "--test-error-sound" ]; then
  error_beep
  exit $?
fi

if [ "${1:-}" = "--list-backup-targets" ]; then
  backup_targets
  exit 0
fi

if [ "${1:-}" = "--identify-zip" ]; then
  if [ -z "${2:-}" ]; then
    echo "Uso: auto-code-manager --identify-zip <arquivo.zip>" >&2
    exit 2
  fi

  identified_project="$(project_for_zip "$(basename -- "$2")")"
  if [ -z "$identified_project" ]; then
    echo "NÃO RECONHECIDO: $(basename -- "$2")" >&2
    exit 1
  fi

  echo "$identified_project"
  exit 0
fi

if [ "${1:-}" = "--import-worker-from-once" ] || [ "${1:-}" = "--import-downloads-once" ]; then
  if [ ! -d "$CODE_ROOT" ]; then
    echo "ERRO: diretório não existe: $CODE_ROOT" >&2
    exit 1
  fi

  if ! validate_projects; then
    echo "ERRO: corrija $PROJECTS_FILE antes de importar." >&2
    exit 1
  fi

  if import_worker_from; then
    taskbar_status done "Importação concluída"
    exit 0
  fi
  taskbar_status error "Falha na importação"
  exit 1
fi

if [ "${1:-}" = "--import-one" ]; then
  if [ -z "${2:-}" ]; then
    echo "Uso: auto-code-manager --import-one <arquivo.zip>" >&2
    exit 2
  fi

  if [ ! -d "$CODE_ROOT" ]; then
    echo "ERRO: diretório não existe: $CODE_ROOT" >&2
    exit 1
  fi

  if ! validate_projects; then
    echo "ERRO: corrija $PROJECTS_FILE antes de importar." >&2
    exit 1
  fi

  taskbar_status unzip "Importando $(basename -- "$2")"
  if import_one_zip "$2"; then
    taskbar_status done "Importação concluída"
    exit 0
  fi
  taskbar_status error "Falha na importação"
  error_beep
  exit 1
fi

if [ "${1:-}" = "--sql-zip-once" ]; then
  if [ ! -d "$CODE_ROOT" ]; then
    echo "ERRO: diretório não existe: $CODE_ROOT" >&2
    exit 1
  fi

  if zip_configured_sql_folders; then
    taskbar_status done "SQLs compactados"
    exit 0
  fi
  taskbar_status error "Falha ao compactar SQLs"
  exit 1
fi

if [ ! -d "$CODE_ROOT" ]; then
  echo "ERRO: diretório não existe: $CODE_ROOT" >&2
  exit 1
fi

if ! validate_projects; then
  echo "ERRO: corrija $PROJECTS_FILE antes de iniciar." >&2
  exit 1
fi

if [ "${1:-}" = "--backup-once" ]; then
  if ! validate_backup_ignore_zip; then
    echo "ERRO: backup bloqueado; restaure $IGNORE_ZIP_FILE." >&2
    exit 1
  fi
  taskbar_status backup "Backup manual"
  if zip_configured_sql_folders && clean_unmanaged_backup_zips && backup_all; then
    taskbar_status done "Backup concluído"
    exit 0
  fi
  taskbar_status error "Falha no backup"
  exit 1
fi

if ! validate_backup_ignore_zip; then
  echo "ERRO: monitor não iniciado; restaure $IGNORE_ZIP_FILE." >&2
  exit 1
fi

if ! acquire_monitor_lock; then
  taskbar_status error "Monitor já ativo"
  exit 3
fi

tui_init
if [ "$TUI_ACTIVE" = true ]; then
  TUI_STATUS_STATE="INICIANDO"
  TUI_STATUS_DETAIL="Preparando monitor"
  TUI_LAST_ACTION="Auto Code Manager $SCRIPT_VERSION"
  tui_refresh
  LOG_CONTEXT=wait log "Auto Code Manager $SCRIPT_VERSION iniciado."
  LOG_CONTEXT=wait log "CODE_ROOT=$CODE_ROOT · worker/from=$(worker_from_dir) · modo=${AUTO_CODE_MONITOR_MODE:-light}."
else
  line
  echo "Auto Code Manager - $SCRIPT_VERSION"
  line
  echo "CODE_ROOT:     $CODE_ROOT"
  echo "worker/from:     $(worker_from_dir)"
  echo "ENV:           $ENV_FILE"
  echo "SQL ZIP:       $FOLDER_SQL_ZIP_FILE"
  echo "Modo:          ${AUTO_CODE_MONITOR_MODE:-light} (leve por metadados; sem inotify no modo light)"
  echo "Backup:        ${BACKUP_EVERY}s de silêncio após a última alteração"
  echo "Estável por:   ${STABLE_WAIT}s apenas em processamento manual/baseline"
  line
fi

initialize_pause_control

if ! start_change_monitor; then
  taskbar_status error "Monitor indisponível"
  echo "ERRO: monitor de alterações não pôde ser iniciado." >&2
  exit 1
fi

# Reconciliação única por inicialização. Nada abaixo vira polling: serve apenas
# para capturar trabalho que apareceu enquanto o manager estava desligado.
taskbar_status backup "Baseline inicial"
stage backup start "BACKUP BASELINE — INÍCIO" "Sincroniza os ZIPs uma única vez ao iniciar; depois somente eventos do filesystem disparam trabalho."
LOG_CONTEXT=backup clean_unmanaged_backup_zips
if LOG_CONTEXT=backup backup_all; then
  stage backup end "BACKUP BASELINE — CONCLUÍDO"
else
  taskbar_status error "Baseline falhou"
  LOG_CONTEXT=error log "ERRO: baseline inicial falhou; monitor encerrado para não operar com backup inconsistente."
  error_beep
  stop_backup_watcher
  exit 1
fi

if is_wsl_runtime; then
  run_stage zone "LIMPEZA ZONE.IDENTIFIER INICIAL" "Compatibilidade WSL: remove resíduos antigos uma única vez; novos sidecars são apagados por evento." clean_zone || true
fi
run_stage downloads "WORKER/FROM INICIAL" "Importa somente ZIPs que já estavam em worker/from antes do watcher iniciar; depois cada ZIP chega por evento." import_worker_from || true
run_stage sql "SQLs INICIAIS" "Compacta somente SQLs que já existiam antes do watcher iniciar; depois cada pasta é acionada por evento." zip_configured_sql_folders || true

taskbar_status idle "Aguardando eventos"
if [ "$ACTIVE_MONITOR_MODE" = "light" ]; then
  LOG_CONTEXT=wait log "IDLE leve: sem inotify; somente metadados dos projetos configurados a cada ${LIGHT_SCAN_INTERVAL}s."
else
  LOG_CONTEXT=wait log "IDLE event-driven: aguardando inotify; nenhuma varredura periódica de projetos, worker/from ou SQL."
fi

while true; do
  local_timeout=""
  events=""
  event_path=""

  wait_if_paused

  if [ "$ACTIVE_MONITOR_MODE" = "light" ]; then
    if ! light_scan_cycle; then
      taskbar_status error "Monitor leve falhou"
      LOG_CONTEXT=error log "ERRO: monitor leve falhou."
      exit 1
    fi

    if [ "${#DIRTY_BACKUP_TARGETS[@]}" -gt 0 ] && [ "$LAST_SOURCE_CHANGE" -gt 0 ]; then
      now="$(date +%s)"
      if [ $((now - LAST_SOURCE_CHANGE)) -ge "$BACKUP_EVERY" ]; then
        taskbar_status backup "Backup inteligente"
        stage backup start "BACKUP INTELIGENTE — INÍCIO" "Compacta somente projetos alterados e agregadores dependentes."
        if LOG_CONTEXT=backup backup_dirty_targets; then
          stage backup end "BACKUP INTELIGENTE — CONCLUÍDO"
          taskbar_status idle "Aguardando alterações"
        else
          taskbar_status error "Backup inteligente falhou"
          LOG_CONTEXT=error log "ERRO: backup inteligente falhou; alvos permanecem pendentes para nova tentativa."
          LAST_SOURCE_CHANGE="$(date +%s)"
        fi
      fi
    fi

    sleep "$LIGHT_SCAN_INTERVAL"
    continue
  fi

  # Se existe backup pendente, read -t funciona como debounce bloqueante. Sem
  # backup pendente, o read fica bloqueado indefinidamente até chegar um evento.
  if [ "${#DIRTY_BACKUP_TARGETS[@]}" -gt 0 ] && [ "$LAST_SOURCE_CHANGE" -gt 0 ]; then
    now="$(date +%s)"
    remaining=$((BACKUP_EVERY - (now - LAST_SOURCE_CHANGE)))
    if [ "$remaining" -le 0 ]; then
      taskbar_status backup "Backup inteligente"
      stage backup start "BACKUP INTELIGENTE — INÍCIO" "Compacta somente projetos alterados e agregadores dependentes."
      if LOG_CONTEXT=backup backup_dirty_targets; then
        stage backup end "BACKUP INTELIGENTE — CONCLUÍDO"
        taskbar_status idle "Aguardando eventos"
      else
        taskbar_status error "Backup inteligente falhou"
        LOG_CONTEXT=error log "ERRO: backup inteligente falhou; alvos permanecem pendentes para nova tentativa."
        LAST_SOURCE_CHANGE="$(date +%s)"
      fi
      continue
    fi
    local_timeout="$remaining"
  fi

  if [ -n "$local_timeout" ]; then
    if IFS=$'\t' read -r -t "$local_timeout" -u "$WATCH_FD" events event_path; then
      handle_watch_event "$events" "$event_path"
    else
      # Timeout = debounce venceu. Se o produtor morreu, o FD somente-leitura
      # também retorna e a checagem abaixo reinicia o watcher.
      if ! backup_watcher_alive; then
        LOG_CONTEXT=error log "ERRO: watcher inotify encerrou inesperadamente; reiniciando."
        if ! start_backup_watcher; then
          taskbar_status error "Watcher inotify falhou"
          exit 1
        fi
      fi
    fi
  else
    # Estado ocioso real: este read não tem timeout e não consome CPU enquanto
    # nenhum arquivo muda.
    if ! IFS=$'\t' read -r -u "$WATCH_FD" events event_path; then
      LOG_CONTEXT=error log "ERRO: watcher inotify encerrou inesperadamente; reiniciando."
      if ! start_backup_watcher; then
        taskbar_status error "Watcher inotify falhou"
        exit 1
      fi
      continue
    fi
    handle_watch_event "$events" "$event_path"
  fi

  if ! reload_backup_watcher_if_needed; then
    taskbar_status error "Configuração inválida"
    stop_backup_watcher
    exit 1
  fi

done
