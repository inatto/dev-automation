#!/usr/bin/env bash
# Contexto: cores, log, etapas, status, lock e pausa

color_enabled() {
  [ -t 1 ] && [ "${NO_COLOR:-}" = "" ] && [ "${TERM:-dumb}" != "dumb" ]
}

color_code() {
  case "$1" in
    cycle) printf '1;36' ;;    # ciano forte
    downloads) printf '1;34' ;;# azul
    sql) printf '1;35' ;;      # magenta
    zone) printf '1;33' ;;     # amarelo
    backup) printf '1;32' ;;   # verde
    wait) printf '2;37' ;;     # cinza
    error) printf '1;31' ;;    # vermelho
    *) printf '0' ;;
  esac
}

paint() {
  local context="$1"
  shift
  if color_enabled; then
    printf '\033[%sm%s\033[0m' "$(color_code "$context")" "$*"
  else
    printf '%s' "$*"
  fi
}

log() {
  local message="$*"
  local context="${LOG_CONTEXT:-}"

  if [[ "$message" == ERRO:* ]]; then
    context="error"
  fi

  if [ "$TUI_ACTIVE" = true ]; then
    tui_log_line "$context" "$message"
    return 0
  fi

  printf '[%s] ' "$(date '+%Y-%m-%d %H:%M:%S')"
  if [ -n "$context" ]; then
    paint "$context" "$message"
    printf '\n'
  else
    printf '%s\n' "$message"
  fi
}

tray_state_for_context() {
  case "$1" in
    cycle) printf 'sync' ;;
    downloads) printf 'unzip' ;;
    sql) printf 'zip' ;;
    zone) printf 'clean' ;;
    backup) printf 'backup' ;;
    wait) printf 'idle' ;;
    error) printf 'error' ;;
    *) printf 'idle' ;;
  esac
}

stage() {
  local context="$1"
  local state="$2"
  local title="$3"
  local description="${4:-}"
  local marker='▶'

  [ "$state" = 'end' ] && marker='✓'
  [ "$state" = 'skip' ] && marker='·'

  taskbar_status "$(tray_state_for_context "$context")" "$title"

  if [ "$TUI_ACTIVE" = true ]; then
    TUI_LAST_ACTION="$title"
    tui_refresh
    LOG_CONTEXT="$context" log "$marker $title${description:+ — $description}"
    return 0
  fi

  printf '\n'
  paint "$context" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf '\n'
  paint "$context" "$marker $title"
  printf '\n'
  if [ -n "$description" ]; then
    paint "$context" "  $description"
    printf '\n'
  fi
  paint "$context" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf '\n'
}

taskbar_status() {
  local state="$1"
  local detail="${2:-}"
  local invoke_windows
  local pause_file_windows

  TUI_STATUS_STATE="$(tui_state_label "$state")"
  TUI_STATUS_DETAIL="$detail"
  case "$state" in
    idle|paused) ;;
    *) [ -z "$detail" ] || TUI_LAST_ACTION="$detail" ;;
  esac
  [ "$TUI_ACTIVE" = true ] && tui_refresh

  [ "${TASKBAR_STATUS_ENABLED:-true}" = true ] || return 0
  [ -f "$DEV_STATUS_EXE" ] || return 0
  [ -f "$DEV_STATUS_INVOKE_PS1" ] || return 0
  command -v powershell.exe >/dev/null 2>&1 || return 0
  command -v wslpath >/dev/null 2>&1 || return 0

  invoke_windows="$(wslpath -w "$DEV_STATUS_INVOKE_PS1" 2>/dev/null)" || return 0
  pause_file_windows="$(wslpath -w "$PAUSE_FILE" 2>/dev/null)" || return 0
  powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$invoke_windows" -State "$state" -Detail "$detail" -PauseFile "$pause_file_windows" </dev/null >/dev/null 2>&1 || true
}

acquire_monitor_lock() {
  mkdir -p -- "$STATE_DIR"
  command -v flock >/dev/null 2>&1 || {
    log "ERRO: flock não encontrado; monitor único não pode ser garantido."
    return 1
  }

  exec {MONITOR_LOCK_FD}>>"$MONITOR_LOCK_FILE"
  if ! flock -n "$MONITOR_LOCK_FD"; then
    local active_pid
    active_pid="$(head -n 1 "$MONITOR_LOCK_FILE" 2>/dev/null || true)"
    log "ERRO: já existe um Auto Code Manager ativo${active_pid:+ (PID $active_pid)}."
    return 1
  fi

  : > "$MONITOR_LOCK_FILE"
  printf '%s\n' "$$" >&"$MONITOR_LOCK_FD"
  return 0
}

initialize_pause_control() {
  mkdir -p -- "$STATE_DIR"
  rm -f -- "$PAUSE_FILE"
  PAUSE_CONTROL_ACTIVE=true
}

wait_if_paused() {
  local announced=false

  [ "$PAUSE_CONTROL_ACTIVE" = true ] || return 0

  while [ -f "$PAUSE_FILE" ]; do
    if [ "$announced" = false ]; then
      taskbar_status paused "Pausado"
      LOG_CONTEXT=wait log "PAUSADO — botão direito no ícone da bandeja para despausar."
      announced=true
    fi
    sleep 0.25
  done

  if [ "$announced" = true ]; then
    LOG_CONTEXT=wait log "DESPAUSADO — monitor retomado."
    taskbar_status idle "Monitorando"
  fi
}

run_stage() {
  local context="$1"
  local title="$2"
  local description="$3"
  shift 3

  wait_if_paused
  stage "$context" start "$title — INÍCIO" "$description"
  if LOG_CONTEXT="$context" "$@"; then
    stage "$context" end "$title — CONCLUÍDO"
    return 0
  fi

  taskbar_status error "$title"
  LOG_CONTEXT=error log "ERRO: etapa '$title' terminou com falha."
  error_beep
  return 1
}

line() {
  [ "$TUI_ACTIVE" = true ] && return 0
  echo "────────────────────────────────────────────────────────────"
}

