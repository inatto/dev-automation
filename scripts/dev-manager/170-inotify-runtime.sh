#!/usr/bin/env bash
# Contexto: lifecycle do watcher inotify e tratamento de eventos

stop_backup_watcher() {
  if [ -n "${WATCH_PID:-}" ] && kill -0 "$WATCH_PID" 2>/dev/null; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  WATCH_PID=""

  if [ -n "${WATCH_FD:-}" ]; then
    eval "exec ${WATCH_FD}>&-" 2>/dev/null || true
    WATCH_FD=""
  fi

  [ -z "${WATCH_FIFO:-}" ] || rm -f -- "$WATCH_FIFO"
  [ -z "${WATCH_LIST:-}" ] || rm -f -- "$WATCH_LIST"
  WATCH_FIFO=""
  WATCH_LIST=""
}

path_is_within_absolute() {
  local path="$1"
  local root="$2"
  [ "$path" = "$root" ] || [[ "$path" == "$root/"* ]]
}

path_is_covered_by_roots() {
  local path="$1"
  shift
  local root
  for root in "$@"; do
    if path_is_within_absolute "$path" "$root"; then
      return 0
    fi
  done
  return 1
}

append_nonrecursive_watch_root() {
  local root="$1"
  local child

  [ -d "$root" ] || return 0
  printf '%s\n' "$root" >> "$WATCH_LIST"

  # O watcher principal usa -r. Para pastas SQL que não pertencem a um
  # projeto, excluímos subdiretórios para manter o watch não recursivo e barato.
  while IFS= read -r -d '' child; do
    printf '@%s\n' "$child" >> "$WATCH_LIST"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
}

start_backup_watcher() {
  local exclude_regex root excluded downloads sql_folder bootstrap_fd read_fd
  local watched_aux=0
  local -a roots=()
  local -a command=()

  command -v inotifywait >/dev/null 2>&1 || {
    log "ERRO: inotifywait não encontrado. Instale uma vez: sudo apt-get install -y inotify-tools"
    return 1
  }

  mapfile -t roots < <(watch_root_projects)
  if [ "${#roots[@]}" -eq 0 ]; then
    log "ERRO: nenhum projeto normal configurado para monitorar."
    return 1
  fi

  stop_backup_watcher
  mkdir -p "$STATE_DIR"
  WATCH_FIFO="$STATE_DIR/backup-events.fifo"
  WATCH_LIST="$STATE_DIR/inotify-paths.txt"
  WATCH_LOG="$STATE_DIR/inotifywait.log"
  rm -f -- "$WATCH_FIFO" "$WATCH_LIST"
  mkfifo "$WATCH_FIFO"
  : > "$WATCH_LIST"

  # Projetos Linux: watch recursivo, mas sem .git/.venv/node_modules/etc.
  for root in "${roots[@]}"; do
    printf '%s\n' "$root" >> "$WATCH_LIST"
    while IFS= read -r excluded || [ -n "$excluded" ]; do
      [ -n "$excluded" ] || continue
      printf '@%s\n' "$excluded" >> "$WATCH_LIST"
    done < <(watch_excluded_directories "$root")
  done

  # Downloads: observado somente no primeiro nível. Subpastas não entram na
  # fila; só ZIPs fechados/renomeados diretamente em ~/Downloads interessam.
  downloads="$(download_inbox_dir)"
  if [ -n "$downloads" ] && [ -d "$downloads" ] && ! path_is_covered_by_roots "$downloads" "${roots[@]}"; then
    append_nonrecursive_watch_root "$downloads"
    roots+=("$downloads")
    watched_aux=$((watched_aux + 1))
  fi

  # SQL não possui mais automação implícita. Arquivos .sql são tratados como
  # qualquer outro arquivo do projeto e apenas sujam o backup normal.

  # Bootstrap do FIFO: abre R/W só durante a partida para evitar deadlock.
  # Depois trocamos por um FD somente-leitura; assim, se o inotify morrer, o
  # read recebe EOF imediatamente e o manager consegue reiniciar o watcher sem
  # qualquer timer de health-check.
  exec {bootstrap_fd}<>"$WATCH_FIFO"

  exclude_regex="$(build_inotify_exclude_regex)"
  INOTIFY_DIR_EXCLUDE_REGEX="$(build_inotify_directory_regex)"
  command=(inotifywait -m -q -r \
    -e close_write -e create -e delete -e move -e attrib \
    --format $'%e\t%w%f')
  [ -z "$exclude_regex" ] || command+=(--exclude "$exclude_regex")
  command+=(--fromfile "$WATCH_LIST")

  : > "$WATCH_LOG"
  "${command[@]}" >"$WATCH_FIFO" 2>>"$WATCH_LOG" &
  WATCH_PID=$!

  # O produtor já foi aberto; agora o consumidor pode ficar somente em leitura.
  exec {read_fd}<"$WATCH_FIFO"
  eval "exec ${bootstrap_fd}>&-" 2>/dev/null || true
  WATCH_FD="$read_fd"

  sleep 0.15
  if ! kill -0 "$WATCH_PID" 2>/dev/null; then
    log "ERRO: watcher inotify não iniciou. Log: $WATCH_LOG"
    stop_backup_watcher
    return 1
  fi

  log "Monitor event-driven ativo via inotify: ${#roots[@]} raiz(es), $watched_aux raiz(es) auxiliar(es); sem polling de pastas."
  return 0
}

event_has() {
  local events="$1"
  local wanted="$2"
  [[ ",$events," == *",$wanted,"* ]]
}

event_finished_write() {
  local events="$1"
  event_has "$events" CLOSE_WRITE || event_has "$events" MOVED_TO
}

path_is_download_zip() {
  local event_path="$1"
  local downloads
  downloads="$(download_inbox_dir)"
  [ -n "$downloads" ] || return 1
  path_is_within_absolute "$event_path" "$downloads" || return 1
  [ "$(dirname -- "$event_path")" = "$downloads" ] || return 1
  [[ "${event_path,,}" == *.zip ]]
}

mark_all_projects_dirty() {
  local project
  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    target_is_aggregate "$project" && continue
    if [ ! -d "$(project_path "$project")" ]; then
      LOG_CONTEXT=error log "ERRO: projeto configurado não existe; não será marcado para backup: $(project_path "$project")"
      unset 'DIRTY_BACKUP_TARGETS[$project]' 2>/dev/null || true
      continue
    fi
    DIRTY_BACKUP_TARGETS["$project"]=1
  done < <(backup_targets)
  LAST_SOURCE_CHANGE="$(date +%s)"
  LOG_CONTEXT=backup log "Configuração estrutural alterada; projetos registrados marcados para reconciliação após ${BACKUP_EVERY}s de silêncio."
}

handle_watch_event() {
  local events="$1"
  local event_path="$2"
  local owner

  [ -n "$event_path" ] || return 0

  # Compatibilidade WSL apenas. No Linux nativo não existe tratamento especial
  # para Zone.Identifier.
  if is_wsl_runtime && [[ "$event_path" == *":Zone.Identifier" ]]; then
    if event_finished_write "$events" || event_has "$events" ATTRIB || event_has "$events" CREATE; then
      rm -f -- "$event_path" 2>/dev/null || true
    fi
    return 0
  fi

  # Configuração que muda a árvore monitorada. Só reage ao fim da gravação para
  # não validar um arquivo ainda parcial.
  if event_finished_write "$events"; then
    if [ "$event_path" = "$ENV_FILE" ]; then
      load_env
      validate_timers
      WATCH_RELOAD_REQUESTED=true
    elif [ "$event_path" = "$PROJECTS_FILE" ] || [ "$event_path" = "$IGNORE_ZIP_FILE" ]; then
      WATCH_RELOAD_REQUESTED=true
      FORCE_FULL_BACKUP_AFTER_RELOAD=true
    fi
  fi

  # ZIP novo em Downloads: só nomes resolvidos para projeto cadastrado E
  # existente entram. Desconhecidos ficam intocados. CLOSE_WRITE/MOVED_TO
  # garante que o produtor terminou de gravar antes da validação do ZIP.
  if event_finished_write "$events" && path_is_download_zip "$event_path" && [ -f "$event_path" ]; then
    if download_zip_is_configured "$event_path"; then
      if ! run_stage downloads "DOWNLOAD / IMPORTAÇÃO" "ZIP reconhecido em Downloads; valida, faz backup pré-importação, aplica e remove somente após confirmação." \
        import_one_zip "$event_path" true; then
        LOG_CONTEXT=error log "ERRO: importação falhou; ZIP mantido em Downloads: $event_path"
      fi
    fi
    return 0
  fi

  if [ -n "${INOTIFY_DIR_EXCLUDE_REGEX:-}" ] && [[ "$event_path" =~ $INOTIFY_DIR_EXCLUDE_REGEX ]]; then
    # Diretório ignorado criado depois da inicialização: não suja backup e
    # reinicia o watcher para podar essa nova subárvore dos watches.
    if event_has "$events" CREATE || event_has "$events" MOVED_TO; then
      WATCH_RELOAD_REQUESTED=true
    fi
    return 0
  fi

  owner="$(event_owner_project "$event_path")"
  [ -n "$owner" ] || return 0

  # Mudança de .gitignore altera a própria árvore de watches do projeto.
  if [ "$(basename -- "$event_path")" = ".gitignore" ]; then
    WATCH_RELOAD_REQUESTED=true
  elif path_is_git_ignored "$(project_path "$owner")" "$event_path"; then
    # Ignorados pelo Git nunca disparam backup. Se uma nova pasta ignorada
    # apareceu em runtime, recarrega o inotify para remover toda a subárvore.
    if { event_has "$events" CREATE || event_has "$events" MOVED_TO; } && [ -d "$event_path" ]; then
      WATCH_RELOAD_REQUESTED=true
    fi
    return 0
  fi

  mark_backup_dirty "$owner" "$event_path"
}

reload_backup_watcher_if_needed() {
  [ "$WATCH_RELOAD_REQUESTED" = true ] || return 0
  WATCH_RELOAD_REQUESTED=false

  if ! validate_projects; then
    log "ERRO: configuração de projetos ficou inválida; monitor será encerrado antes de qualquer novo backup."
    return 1
  fi
  if ! validate_backup_ignore_zip; then
    log "ERRO: ignore global ficou inválido; monitor será encerrado antes de qualquer novo backup."
    return 1
  fi

  clean_unmanaged_backup_zips || true
  start_backup_watcher || return 1

  # Se mudou .projects/ignore, a composição de qualquer ZIP pode ter mudado.
  # Isso é raro e deliberado; reconcilia uma vez, ainda respeitando o debounce.
  if [ "$FORCE_FULL_BACKUP_AFTER_RELOAD" = true ]; then
    FORCE_FULL_BACKUP_AFTER_RELOAD=false
    mark_all_projects_dirty
  fi

  return 0
}

backup_watcher_alive() {
  [ -n "${WATCH_PID:-}" ] && kill -0 "$WATCH_PID" 2>/dev/null
}

