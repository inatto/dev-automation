#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation
set -uo pipefail
#cd /home/daniel/Code/bots/dev-automation/
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SCRIPT_VERSION="2026-08-12-light-monitor-v27-clipper"

CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
IGNORE_ZIP_FILE="$PROJECT_ROOT/config/auto-code-manager.ignore-zip"
IGNORE_UNZIP_FILE="$PROJECT_ROOT/config/auto-code-manager.ignore-unzip"
PROJECTS_FILE="$PROJECT_ROOT/config/auto-code-manager.projects"
ENV_FILE="$PROJECT_ROOT/config/auto-code-manager.env"
FOLDER_SQL_ZIP_FILE="$PROJECT_ROOT/config/auto-code-manager.folder-sql-zip"
STATE_DIR="${AUTO_CODE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dev-automation}"
PROTECTED_CONFIG_BASELINES_DIR="$STATE_DIR/protected-config-baselines"
PAUSE_FILE="$STATE_DIR/dev-manager.paused"
SOUND_DISABLED_FILE="$STATE_DIR/dev-manager.sound-disabled"
RUNNING_PROJECTS_DIR="$STATE_DIR/running-projects"

# Valores padrão. Podem ser sobrescritos em auto-code-manager.env.
# Monitor leve por metadados: não consome nenhuma instância inotify.
# A cada poucos segundos verifica somente metadados dos projetos configurados,
# podando .gitignore/ignore-zip e sem abrir conteúdo de arquivo.
BACKUP_EVERY=1
LIGHT_SCAN_INTERVAL=2
AUTO_CODE_MONITOR_MODE="${AUTO_CODE_MONITOR_MODE:-light}"
STABLE_WAIT=1
BEEP_REPEATS=2
BEEP_GAP_MS=220
BEEP_MODE="wave"
BEEP_VOLUME=22
BEEP_WAVE_FILE="$PROJECT_ROOT/assets/sounds/soft-notification.wav"
BEEP_WINDOWS_WAVE_FILE="C:\\Windows\\Media\\notify.wav"
BACKUP_BEEP_ENABLED=true
BACKUP_BEEP_VOLUME=18
BACKUP_BEEP_WAVE_FILE="$PROJECT_ROOT/assets/sounds/backup-complete.wav"
BACKUP_WINDOWS_WAVE_FILE="C:\\Windows\\Media\\ding.wav"
ERROR_WINDOWS_WAVE_FILE="C:\\Windows\\Media\\Windows Critical Stop.wav"
TASKBAR_STATUS_ENABLED=true
DEV_STATUS_INVOKE_PS1="$PROJECT_ROOT/apps/dev-status/invoke.ps1"
DEV_STATUS_EXE="$PROJECT_ROOT/apps/dev-status/bin/dev-status.exe"
PAUSE_CONTROL_ACTIVE=false
WATCH_PID=""
WATCH_FIFO=""
WATCH_FD=""
WATCH_LOG=""
WATCH_LIST=""
INOTIFY_DIR_EXCLUDE_REGEX=""
WATCH_RELOAD_REQUESTED=false
FORCE_FULL_BACKUP_AFTER_RELOAD=false
LAST_SOURCE_CHANGE=0
ACTIVE_MONITOR_MODE=""
LIGHT_WATCH_PLAN=""
LIGHT_CONFIG_SIGNATURE=""
declare -A LIGHT_SIGNATURES=()
declare -A LIGHT_TREE_SIGNATURES=()
declare -A LIGHT_IGNORE_SIGNATURES=()
MONITOR_LOCK_FILE="$STATE_DIR/auto-code-manager.monitor.lock"
MONITOR_LOCK_FD=""
declare -A DIRTY_BACKUP_TARGETS=()

# TUI retrô estilo Clipper. Só entra em tela cheia quando stdout é um terminal.
# AUTO_CODE_TUI=off desativa e mantém a saída tradicional.
AUTO_CODE_TUI="${AUTO_CODE_TUI:-clipper}"
TUI_ACTIVE=false
TUI_ROWS=0
TUI_COLS=0
TUI_LOG_TOP=9
TUI_STATUS_STATE="INICIANDO"
TUI_STATUS_DETAIL="Preparando monitor"
TUI_LAST_ACTION="Inicialização"
TUI_METRIC_TS=0
TUI_INOTIFY_INSTANCES=0
TUI_INOTIFY_WATCHES=0
TUI_INOTIFY_MAX_INSTANCES=0
TUI_INOTIFY_MAX_WATCHES=0
TUI_MANAGER_FDS=0
TUI_MANAGER_FD_LIMIT=0
TUI_PROJECT_COUNT=0
TUI_DOWNLOAD_ZIPS=0
TUI_LOG_FILE="$STATE_DIR/dev-manager.log"


load_env() {
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a
    source "$ENV_FILE"
    set +a
  fi
}

validate_positive_integer() {
  local name="$1"
  local value="${!name:-}"

  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERRO: $name deve ser um número inteiro maior que zero. Valor atual: ${value:-<vazio>}" >&2
    exit 1
  fi
}

validate_timers() {
  validate_positive_integer BACKUP_EVERY
  validate_positive_integer STABLE_WAIT
  validate_positive_integer LIGHT_SCAN_INTERVAL
  validate_positive_integer BEEP_REPEATS
  validate_positive_integer BEEP_GAP_MS

  if ! [[ "${BEEP_VOLUME:-}" =~ ^[0-9]+$ ]] || [ "$BEEP_VOLUME" -gt 100 ]; then
    echo "ERRO: BEEP_VOLUME deve ser um inteiro entre 0 e 100. Valor atual: ${BEEP_VOLUME:-<vazio>}" >&2
    exit 1
  fi

  if ! [[ "${BACKUP_BEEP_VOLUME:-}" =~ ^[0-9]+$ ]] || [ "$BACKUP_BEEP_VOLUME" -gt 100 ]; then
    echo "ERRO: BACKUP_BEEP_VOLUME deve ser um inteiro entre 0 e 100. Valor atual: ${BACKUP_BEEP_VOLUME:-<vazio>}" >&2
    exit 1
  fi

  case "${BACKUP_BEEP_ENABLED:-}" in
    true|false) ;;
    *)
      echo "ERRO: BACKUP_BEEP_ENABLED deve ser true ou false. Valor atual: ${BACKUP_BEEP_ENABLED:-<vazio>}" >&2
      exit 1
      ;;
  esac
}

tui_supported() {
  [ "${AUTO_CODE_TUI:-clipper}" != "off" ] || return 1
  [ -t 1 ] || return 1
  [ "${TERM:-dumb}" != "dumb" ] || return 1
  return 0
}

tui_terminal_size() {
  local rows cols
  rows="$(tput lines 2>/dev/null || printf '24')"
  cols="$(tput cols 2>/dev/null || printf '80')"
  [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  printf '%s %s\n' "$rows" "$cols"
}

tui_repeat() {
  local char="$1" count="$2" out=""
  local i
  for ((i=0; i<count; i++)); do out+="$char"; done
  printf '%s' "$out"
}

tui_fit() {
  local text="$1" width="$2"
  text="${text//$'\n'/ }"
  text="${text//$'\r'/ }"
  if [ "${#text}" -gt "$width" ]; then
    if [ "$width" -gt 1 ]; then
      text="${text:0:$((width-1))}…"
    else
      text="${text:0:$width}"
    fi
  fi
  printf '%-*s' "$width" "$text"
}

tui_border_text() {
  local left="$1" right="$2" label="${3:-}"
  local inner=$((TUI_COLS - 2)) body=""
  [ "$inner" -gt 0 ] || return 0
  if [ -n "$label" ]; then
    label=" $label "
    if [ "${#label}" -gt "$inner" ]; then
      label="${label:0:$inner}"
    fi
    body="$label$(tui_repeat '═' $((inner-${#label})))"
  else
    body="$(tui_repeat '═' "$inner")"
  fi
  printf '%s%s%s' "$left" "$body" "$right"
}

tui_write_row() {
  local row="$1" color="$2" text="$3"
  local fitted
  fitted="$(tui_fit "$text" "$TUI_COLS")"
  printf '\033[%s;1H\033[%sm%s\033[0m' "$row" "$color" "$fitted"
}

tui_write_box_row() {
  local row="$1" text="$2" color="${3:-44;97}"
  local inner=$((TUI_COLS - 4))
  [ "$inner" -gt 0 ] || return 0
  tui_write_row "$row" "$color" "║ $(tui_fit "$text" "$inner") ║"
}

tui_write_split_row() {
  local row="$1" left="$2" right="$3" color="${4:-44;97}"
  local usable=$((TUI_COLS - 7)) left_width right_width
  [ "$usable" -gt 4 ] || return 0
  left_width=$((usable / 2))
  right_width=$((usable - left_width))
  tui_write_row "$row" "$color" "║ $(tui_fit "$left" "$left_width") │ $(tui_fit "$right" "$right_width") ║"
}

tui_state_label() {
  case "$1" in
    sync|cycle) printf 'SINCRONIZANDO' ;;
    unzip) printf 'IMPORTANDO' ;;
    zip) printf 'SQL → ZIP' ;;
    clean) printf 'LIMPANDO' ;;
    backup) printf 'BACKUP' ;;
    idle) printf 'ATIVO' ;;
    error) printf 'ERRO' ;;
    paused) printf 'PAUSADO' ;;
    done) printf 'OK' ;;
    exit) printf 'SAINDO' ;;
    *) printf '%s' "${1^^}" ;;
  esac
}

tui_collect_metrics() {
  local now downloads info watches
  local -a inotify_fds=()
  local -a fdinfo_files=()

  now="$(date +%s)"
  if [ "$TUI_METRIC_TS" -gt 0 ] && [ $((now - TUI_METRIC_TS)) -lt 10 ]; then
    return 0
  fi
  TUI_METRIC_TS="$now"

  TUI_INOTIFY_MAX_INSTANCES="$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || printf '0')"
  TUI_INOTIFY_MAX_WATCHES="$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || printf '0')"
  TUI_MANAGER_FD_LIMIT="$(ulimit -n 2>/dev/null || printf '0')"
  TUI_MANAGER_FDS="$(find "/proc/$$/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"

  # Uso real do usuário, sem criar watcher e sem varrer conteúdo dos projetos.
  # find resolve os symlinks /proc em C; mesmo com muitas instâncias é barato.
  mapfile -t inotify_fds < <(
    find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -type l -uid "$(id -u)" \
      -lname 'anon_inode:*inotify*' -print 2>/dev/null || true
  )
  TUI_INOTIFY_INSTANCES="${#inotify_fds[@]}"
  TUI_INOTIFY_WATCHES=0
  if [ "${#inotify_fds[@]}" -gt 0 ]; then
    for info in "${inotify_fds[@]}"; do
      info="${info/\/fd\//\/fdinfo\/}"
      [ -r "$info" ] && fdinfo_files+=("$info")
    done
    if [ "${#fdinfo_files[@]}" -gt 0 ]; then
      watches="$(grep -h '^inotify ' "${fdinfo_files[@]}" 2>/dev/null | wc -l | tr -d ' ')"
      [[ "$watches" =~ ^[0-9]+$ ]] && TUI_INOTIFY_WATCHES="$watches"
    fi
  fi

  TUI_PROJECT_COUNT="$(backup_targets 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  downloads="$(downloads_dir 2>/dev/null || true)"
  if [ -n "$downloads" ] && [ -d "$downloads" ]; then
    TUI_DOWNLOAD_ZIPS="$(find "$downloads" -maxdepth 1 -type f -iname '*.zip' 2>/dev/null | wc -l | tr -d ' ')"
  else
    TUI_DOWNLOAD_ZIPS=0
  fi
}

tui_draw_static() {
  local dirty mode manager_inotify now top bottom
  [ "$TUI_ACTIVE" = true ] || return 0
  tui_collect_metrics

  dirty="${#DIRTY_BACKUP_TARGETS[@]}"
  mode="${ACTIVE_MONITOR_MODE:-${AUTO_CODE_MONITOR_MODE:-light}}"
  now="$(date '+%H:%M:%S')"
  manager_inotify=0
  [ "$mode" = "inotify" ] && manager_inotify=1

  printf '\0337'
  tui_write_row 1 '44;96;1' "$(tui_border_text '╔' '╗' 'DEV AUTOMATION :: CLIPPER')"
  tui_write_split_row 2 "STATUS: $TUI_STATUS_STATE  $TUI_STATUS_DETAIL" "HORA: $now" '44;93;1'
  tui_write_split_row 3 "MODO: ${mode^^} · scan ${LIGHT_SCAN_INTERVAL}s · manager inotify: $manager_inotify" "PROJETOS: $TUI_PROJECT_COUNT · PENDENTES: $dirty" '44;97'
  tui_write_split_row 4 "INOTIFY INST: $TUI_INOTIFY_INSTANCES/$TUI_INOTIFY_MAX_INSTANCES" "WATCHES: $TUI_INOTIFY_WATCHES/$TUI_INOTIFY_MAX_WATCHES" '44;96;1'
  tui_write_split_row 5 "FD MANAGER: $TUI_MANAGER_FDS/$TUI_MANAGER_FD_LIMIT" "ZIPs DOWNLOADS: $TUI_DOWNLOAD_ZIPS" '44;97'
  tui_write_row 6 '44;96;1' "$(tui_border_text '╠' '╣' 'ÚLTIMA AÇÃO')"
  tui_write_box_row 7 "$TUI_LAST_ACTION" '44;93;1'
  tui_write_row 8 '44;96;1' "$(tui_border_text '╠' '╣' 'LOG · área rolável')"
  tui_write_row "$TUI_ROWS" '44;96;1' "$(tui_border_text '╚' '╝' 'CTRL+C sair')"
  printf '\0338'
}

tui_relayout() {
  local size rows cols
  [ "$TUI_ACTIVE" = true ] || return 0
  size="$(tui_terminal_size)"
  read -r rows cols <<<"$size"
  if [ "$rows" -lt 16 ] || [ "$cols" -lt 80 ]; then
    return 1
  fi
  TUI_ROWS="$rows"
  TUI_COLS="$cols"
  TUI_LOG_TOP=9

  printf '\033[r\033[2J\033[H\033[44m'
  printf '\033[%s;%sr' "$TUI_LOG_TOP" "$((TUI_ROWS-1))"
  tui_draw_static
  printf '\033[%s;1H\033[44;97m' "$TUI_LOG_TOP"
}

tui_refresh() {
  local size rows cols
  [ "$TUI_ACTIVE" = true ] || return 0
  size="$(tui_terminal_size)"
  read -r rows cols <<<"$size"
  if [ "$rows" != "$TUI_ROWS" ] || [ "$cols" != "$TUI_COLS" ]; then
    tui_relayout || return 0
  else
    tui_draw_static
  fi
}

tui_init() {
  local size rows cols
  tui_supported || return 0
  size="$(tui_terminal_size)"
  read -r rows cols <<<"$size"
  if [ "$rows" -lt 16 ] || [ "$cols" -lt 80 ]; then
    return 0
  fi

  mkdir -p -- "$STATE_DIR"
  : > "$TUI_LOG_FILE"
  TUI_ACTIVE=true
  printf '\033[?1049h\033[?25l'
  tui_relayout || {
    tui_cleanup
    return 0
  }
}

tui_log_line() {
  local context="$1" message="$2" color='44;97'
  local stamp
  [ "$TUI_ACTIVE" = true ] || return 1
  stamp="$(date '+%H:%M:%S')"
  case "$context" in
    error) color='44;91;1' ;;
    backup) color='44;92;1' ;;
    downloads|cycle) color='44;96;1' ;;
    sql) color='44;95;1' ;;
    zone) color='44;93;1' ;;
    wait) color='44;37' ;;
  esac
  printf '[%s] %s\n' "$stamp" "$message" >> "$TUI_LOG_FILE" 2>/dev/null || true
  tui_refresh
  printf '\033[%sm[%s] %s\033[0m\033[44;97m\n' "$color" "$stamp" "$message"
  return 0
}

tui_cleanup() {
  [ "$TUI_ACTIVE" = true ] || return 0
  TUI_ACTIVE=false
  printf '\033[r\033[0m\033[?25h\033[?1049l'
}

tui_on_resize() {
  [ "$TUI_ACTIVE" = true ] || return 0
  tui_relayout || true
}

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

soft_beep() {
  [ ! -f "$SOUND_DISABLED_FILE" ] || return 0

  local repeats="${BEEP_REPEATS:-2}"
  local gap_ms="${BEEP_GAP_MS:-220}"
  local mode="${BEEP_MODE:-wave}"
  local volume="${BEEP_VOLUME:-22}"
  local wave_file="${BEEP_WAVE_FILE:-$PROJECT_ROOT/assets/sounds/soft-notification.wav}"
  local windows_wave="${BEEP_WINDOWS_WAVE_FILE:-C:\\Windows\\Media\\notify.wav}"
  local bundled_windows=""
  local powershell_cmd=""
  local powershell_probe=""
  local powershell_script=""
  local audio_result=""
  local i

  line
  log "AVISO SONORO: iniciando ($repeats toque(s), modo=$mode, volume=$volume%)"

  # No WSLg, PulseAudio/PipeWire normalmente é a rota mais direta e não depende
  # da interoperabilidade com executáveis do Windows.
  if [ "$mode" = "wave" ] && [ -r "$wave_file" ]; then
    if command -v paplay >/dev/null 2>&1; then
      log "AVISO SONORO: tentando WAV pelo paplay do WSL..."
      for ((i = 0; i < repeats; i++)); do
        if ! paplay --volume="$((volume * 65536 / 100))" "$wave_file" >/dev/null 2>&1; then
          break
        fi
        [ "$i" -ge $((repeats - 1)) ] || sleep "$(awk "BEGIN { print $gap_ms / 1000 }")"
      done
      if [ "$i" -eq "$repeats" ]; then
        log "AVISO SONORO: WAV tocado pelo áudio nativo do WSL (paplay)."
        line
        return 0
      fi
      log "AVISO SONORO: paplay existe, mas não conseguiu tocar o WAV."
    fi

    if command -v pw-play >/dev/null 2>&1; then
      log "AVISO SONORO: tentando WAV pelo PipeWire do WSL..."
      for ((i = 0; i < repeats; i++)); do
        if ! pw-play --volume="$(awk "BEGIN { print $volume / 100 }")" "$wave_file" >/dev/null 2>&1; then
          break
        fi
        [ "$i" -ge $((repeats - 1)) ] || sleep "$(awk "BEGIN { print $gap_ms / 1000 }")"
      done
      if [ "$i" -eq "$repeats" ]; then
        log "AVISO SONORO: WAV tocado pelo áudio nativo do WSL (pw-play)."
        line
        return 0
      fi
      log "AVISO SONORO: pw-play existe, mas não conseguiu tocar o WAV."
    fi

    if command -v aplay >/dev/null 2>&1; then
      log "AVISO SONORO: tentando WAV pelo ALSA do WSL..."
      for ((i = 0; i < repeats; i++)); do
        if ! aplay -q "$wave_file" >/dev/null 2>&1; then
          break
        fi
        [ "$i" -ge $((repeats - 1)) ] || sleep "$(awk "BEGIN { print $gap_ms / 1000 }")"
      done
      if [ "$i" -eq "$repeats" ]; then
        log "AVISO SONORO: WAV tocado pelo áudio nativo do WSL (aplay)."
        line
        return 0
      fi
      log "AVISO SONORO: aplay existe, mas não conseguiu tocar o WAV."
    fi
  fi

  powershell_cmd="$(command -v powershell.exe 2>/dev/null || true)"
  if [ -n "$powershell_cmd" ]; then
    powershell_probe="$($powershell_cmd -NoLogo -NoProfile -NonInteractive -Command "exit 0" 2>&1 || true)"
    if [ -z "$powershell_probe" ]; then
      log "AVISO SONORO: interoperabilidade WSL/Windows operacional."

      if [ "$mode" = "wave" ]; then
        if [ -r "$wave_file" ] && command -v wslpath >/dev/null 2>&1; then
          bundled_windows="$(wslpath -w "$wave_file" 2>/dev/null || true)"
        fi

        powershell_script="\$ErrorActionPreference = 'Stop';
          \$candidates = @('$windows_wave', '$bundled_windows') | Where-Object { \$_ -and (Test-Path -LiteralPath \$_) };
          if (\$candidates.Count -eq 0) { throw 'Nenhum arquivo WAV foi encontrado.' }
          foreach (\$wav in \$candidates) {
            try {
              \$player = New-Object System.Media.SoundPlayer;
              \$player.SoundLocation = \$wav;
              \$player.Load();
              for (\$i = 0; \$i -lt $repeats; \$i++) {
                \$player.PlaySync();
                if (\$i -lt ($repeats - 1)) { Start-Sleep -Milliseconds $gap_ms }
              }
              Write-Output ('OK|' + \$wav);
              exit 0;
            } catch {
              Write-Output ('FALHOU|' + \$wav + '|' + \$_.Exception.Message);
            }
          }
          exit 2"

        audio_result="$($powershell_cmd -NoLogo -NoProfile -NonInteractive -STA -Command "$powershell_script" 2>&1 | tr -d '\r')"
        if grep -q '^OK|' <<< "$audio_result"; then
          log "AVISO SONORO: WAV tocado pelo Windows: $(grep '^OK|' <<< "$audio_result" | tail -n1 | cut -d'|' -f2-)"
          line
          return 0
        fi
        log "AVISO SONORO: Windows não conseguiu tocar o WAV. Retorno: ${audio_result:-<sem retorno>}"
      fi

      log "AVISO SONORO: tentando beep eletrônico pelo Windows..."
      if "$powershell_cmd" -NoLogo -NoProfile -NonInteractive -Command \
        "for (\$i = 0; \$i -lt $repeats; \$i++) { [console]::beep(880,220); if (\$i -lt ($repeats - 1)) { Start-Sleep -Milliseconds $gap_ms } }" \
        >/dev/null 2>&1; then
        log "AVISO SONORO: beep eletrônico enviado ao Windows."
        line
        return 0
      fi
      log "AVISO SONORO: beep eletrônico do Windows também falhou."
    else
      log "AVISO SONORO: powershell.exe existe, mas o WSL não consegue executá-lo."
      log "AVISO SONORO: retorno da interoperabilidade: $powershell_probe"
    fi
  else
    log "AVISO SONORO: powershell.exe não está disponível no PATH do WSL."
  fi

  log "AVISO SONORO: tentando campainha do terminal/TTY..."
  local tty_ok=false
  for ((i = 0; i < repeats; i++)); do
    if printf '\a' > /dev/tty 2>/dev/null; then
      tty_ok=true
    else
      printf '\a'
    fi
    [ "$i" -ge $((repeats - 1)) ] || sleep "$(awk "BEGIN { print $gap_ms / 1000 }")"
  done

  if [ "$tty_ok" = true ]; then
    log "AVISO SONORO: campainha enviada ao TTY, mas o terminal pode estar silenciando-a."
  else
    log "AVISO SONORO: nenhuma saída de áudio disponível."
  fi
  line
  return 1
}

error_beep() {
  [ ! -f "$SOUND_DISABLED_FILE" ] || return 0

  # Erro usa um som diferente do aviso de importação. No Windows tentamos o
  # Critical Stop; sem interoperabilidade, caímos no beep eletrônico/TTY.
  (
    BEEP_REPEATS=2
    BEEP_GAP_MS=140
    BEEP_MODE="wave"
    BEEP_VOLUME=28
    BEEP_WAVE_FILE="__dev_automation_error_wave_missing__"
    BEEP_WINDOWS_WAVE_FILE="${ERROR_WINDOWS_WAVE_FILE:-C:\\Windows\\Media\\Windows Critical Stop.wav}"
    soft_beep
  ) >/dev/null 2>&1 || true
  return 0
}

backup_beep() {
  [ ! -f "$SOUND_DISABLED_FILE" ] || return 0
  [ "${BACKUP_BEEP_ENABLED:-true}" = "true" ] || return 0

  local windows_wave="${BACKUP_WINDOWS_WAVE_FILE:-C:\\Windows\\Media\\ding.wav}"
  local powershell_cmd=""
  local escaped_windows_wave=""

  # O backup usa prioritariamente o som nativo solicitado do Windows. O
  # SoundPlayer respeita o volume geral do sistema e bloqueia até o fim do WAV,
  # evitando sobreposição quando vários backups terminam em sequência.
  powershell_cmd="$(command -v powershell.exe 2>/dev/null || true)"
  if [ -n "$powershell_cmd" ]; then
    escaped_windows_wave="${windows_wave//\'/\'\'}"
    if "$powershell_cmd" -NoLogo -NoProfile -NonInteractive -STA -Command \
      "\$ErrorActionPreference = 'Stop'; \
       \$wav = '$escaped_windows_wave'; \
       if (-not (Test-Path -LiteralPath \$wav)) { throw 'Arquivo WAV de backup não encontrado.' }; \
       \$player = New-Object System.Media.SoundPlayer; \
       \$player.SoundLocation = \$wav; \
       \$player.Load(); \
       \$player.PlaySync()" \
      >/dev/null 2>&1; then
      return 0
    fi
  fi

  # Fallback discreto para ambientes sem interoperabilidade WSL/Windows ou sem
  # o ding.wav. Não altera o aviso sonoro usado após downloads/importações.
  (
    BEEP_REPEATS=1
    BEEP_GAP_MS=1
    BEEP_MODE="wave"
    BEEP_VOLUME="${BACKUP_BEEP_VOLUME:-18}"
    BEEP_WAVE_FILE="${BACKUP_BEEP_WAVE_FILE:-$PROJECT_ROOT/assets/sounds/backup-complete.wav}"
    BEEP_WINDOWS_WAVE_FILE="__backup_native_wave_disabled__"
    soft_beep
  ) >/dev/null 2>&1 || true

  return 0
}

downloads_dir() {
  local configured_downloads="${DOWNLOADS_DIR:-}"
  local canonical_downloads="${HOME}/Downloads"

  # Override existe apenas para testes/execuções explicitamente isoladas.
  # No uso normal, Downloads é sempre o filesystem Linux do WSL:
  #   /home/<usuario>/Downloads
  # Nunca fazemos fallback para /mnt/c nem consultamos %USERPROFILE%.
  if [ -n "$configured_downloads" ]; then
    printf '%s\n' "$configured_downloads"
    return
  fi

  printf '%s\n' "$canonical_downloads"
}

ensure_downloads_dir() {
  local downloads
  downloads="$(downloads_dir)"

  if [ -z "$downloads" ]; then
    echo "ERRO: caminho de Downloads WSL não pôde ser determinado." >&2
    exit 1
  fi

  if ! mkdir -p -- "$downloads"; then
    echo "ERRO: não foi possível preparar Downloads WSL: $downloads" >&2
    exit 1
  fi
}

stable_file() {
  local file="$1"
  local size_before
  local size_after

  [ -f "$file" ] || return 1

  size_before="$(stat -c %s "$file" 2>/dev/null || echo 0)"
  sleep "$STABLE_WAIT"

  [ -f "$file" ] || return 1

  size_after="$(stat -c %s "$file" 2>/dev/null || echo 0)"

  [ "$size_before" = "$size_after" ] &&
    [ "$size_before" -gt 0 ]
}

clean_file() {
  local file="$1"

  [ -f "$file" ] || return 0

  sed -E \
    -e 's/\r$//' \
    -e 's/^[[:space:]]+//' \
    -e 's/[[:space:]]+$//' \
    -e '/^$/d' \
    -e '/^#/d' \
    "$file"
}

ensure_files() {
  [ -f "$FOLDER_SQL_ZIP_FILE" ] || touch "$FOLDER_SQL_ZIP_FILE"
  [ -f "$IGNORE_UNZIP_FILE" ] || touch "$IGNORE_UNZIP_FILE"

  if [ ! -f "$PROJECTS_FILE" ]; then
    echo "site-inst" > "$PROJECTS_FILE"
  fi
}

validate_backup_ignore_zip() {
  local required
  local -a active_rules=()
  local -a required_rules=(
    ".git/"
    ".venv/"
    "venv/"
    "node_modules/"
  )

  if [ ! -f "$IGNORE_ZIP_FILE" ]; then
    log "ERRO DE SEGURANÇA: ignore global de ZIP não existe: $IGNORE_ZIP_FILE"
    log "Backup bloqueado para evitar compactar dependências, ambientes virtuais e caches gigantes."
    return 1
  fi

  mapfile -t active_rules < <(clean_file "$IGNORE_ZIP_FILE")
  if [ "${#active_rules[@]}" -eq 0 ]; then
    log "ERRO DE SEGURANÇA: ignore global de ZIP está vazio: $IGNORE_ZIP_FILE"
    log "Backup bloqueado para evitar ZIPs gigantes."
    return 1
  fi

  for required in "${required_rules[@]}"; do
    if ! printf '%s\n' "${active_rules[@]}" | grep -Fxq -- "$required"; then
      log "ERRO DE SEGURANÇA: regra obrigatória ausente no ignore global de ZIP: $required"
      log "Arquivo: $IGNORE_ZIP_FILE"
      log "Backup bloqueado para evitar ZIPs gigantes."
      return 1
    fi
  done

  return 0
}

normalize_target() {
  local target="$1"
  target="${target#./}"
  target="${target%/}"
  printf '%s\n' "$target"
}

target_is_aggregate() {
  local target
  target="$(normalize_target "$1")"
  [[ "${target,,}" == *.zip ]]
}

target_is_code_aggregate() {
  local target
  target="$(normalize_target "$1")"
  [[ "$target" != */* && "${target,,}" == "code.zip" ]]
}

target_source_rel() {
  local target
  target="$(normalize_target "$1")"

  if target_is_code_aggregate "$target"; then
    printf '\n'
  elif target_is_aggregate "$target"; then
    printf '%s\n' "${target:0:${#target}-4}"
  else
    printf '%s\n' "$target"
  fi
}

project_path() {
  local project="$1"
  local source_rel
  source_rel="$(target_source_rel "$project")"

  if [ -z "$source_rel" ]; then
    printf '%s\n' "$CODE_ROOT"
  else
    printf '%s/%s\n' "$CODE_ROOT" "$source_rel"
  fi
}

project_logical_name() {
  local project="$1"
  local source_rel

  source_rel="$(target_source_rel "$project")"
  [ -n "$source_rel" ] || return 1
  basename -- "$source_rel"
}

registered_parent_project() {
  local project="$1"
  local project_rel candidate candidate_rel
  local best=""
  local best_len=-1

  target_is_aggregate "$project" && return 0
  project_rel="$(target_source_rel "$project")"

  while IFS= read -r candidate || [ -n "$candidate" ]; do
    [ -n "$candidate" ] || continue
    [ "$candidate" != "$project" ] || continue
    target_is_aggregate "$candidate" && continue
    candidate_rel="$(target_source_rel "$candidate")"
    path_is_descendant "$project_rel" "$candidate_rel" || continue

    if [ "${#candidate_rel}" -gt "$best_len" ]; then
      best="$candidate"
      best_len="${#candidate_rel}"
    fi
  done < <(backup_targets)

  printf '%s\n' "$best"
}

project_archive_name() {
  local project="$1"
  local normalized logical_name parent parent_name

  normalized="$(normalize_target "$project")"
  if target_is_aggregate "$normalized"; then
    normalized="${normalized:0:${#normalized}-4}"
    basename -- "$normalized"
    return 0
  fi

  logical_name="$(project_logical_name "$normalized")"
  parent="$(registered_parent_project "$normalized")"
  if [ -n "$parent" ]; then
    parent_name="$(project_logical_name "$parent")"
    printf '%s--%s\n' "$parent_name" "$logical_name"
  else
    printf '%s\n' "$logical_name"
  fi
}

project_import_names() {
  local project="$1"
  local canonical logical

  canonical="$(project_archive_name "$project")"
  printf '%s\n' "$canonical"

  if ! target_is_aggregate "$project"; then
    logical="$(project_logical_name "$project")"
    if [ "${logical,,}" != "${canonical,,}" ]; then
      printf '%s\n' "$logical"
    fi
  fi
}

project_archive_path() {
  local project="$1"
  local archive_name

  archive_name="$(project_archive_name "$project")"
  printf '%s/%s.zip\n' "$CODE_ROOT" "$archive_name"
}

configured_projects() {
  clean_file "$PROJECTS_FILE"
}

backup_targets() {
  local project
  declare -A seen=()

  # A lista .projects é a única fonte da verdade. Nenhum agrupador é inferido.
  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    project="$(normalize_target "$project")"

    if [ -z "${seen[$project]+x}" ]; then
      printf '%s\n' "$project"
      seen["$project"]=1
    fi
  done < <(configured_projects)
}

path_is_descendant() {
  local child="$1"
  local parent="$2"

  [ -n "$child" ] || return 1
  if [ -z "$parent" ]; then
    return 0
  fi

  [[ "$child" == "$parent/"* ]]
}

aggregate_child_targets() {
  local aggregate="$1"
  local aggregate_rel target target_rel other other_rel covered
  local -a targets=()
  local -a aggregates=()

  aggregate_rel="$(target_source_rel "$aggregate")"
  mapfile -t targets < <(backup_targets)

  # Descendentes agregadores explícitos podem representar um ramo inteiro.
  for target in "${targets[@]}"; do
    [ "$target" != "$aggregate" ] || continue
    target_is_aggregate "$target" || continue
    target_is_code_aggregate "$target" && continue
    target_rel="$(target_source_rel "$target")"
    path_is_descendant "$target_rel" "$aggregate_rel" || continue
    aggregates+=("$target")
  done

  # Em ordem do .projects, seleciona apenas a representação mais alta de cada
  # ramo: agregador explícito cobre seus descendentes; projeto normal nunca
  # cobre subprojetos cadastrados, porque o ZIP dele os exclui fisicamente.
  for target in "${targets[@]}"; do
    [ "$target" != "$aggregate" ] || continue
    target_is_code_aggregate "$target" && continue
    target_rel="$(target_source_rel "$target")"
    path_is_descendant "$target_rel" "$aggregate_rel" || continue

    covered=false
    for other in "${aggregates[@]}"; do
      [ "$other" != "$target" ] || continue
      other_rel="$(target_source_rel "$other")"
      if path_is_descendant "$target_rel" "$other_rel"; then
        covered=true
        break
      fi
    done

    [ "$covered" = false ] || continue
    printf '%s\n' "$target"
  done
}

registered_subprojects() {
  local parent="$1"
  local parent_rel target target_rel

  parent_rel="$(target_source_rel "$parent")"
  while IFS= read -r target || [ -n "$target" ]; do
    [ -n "$target" ] || continue
    [ "$target" != "$parent" ] || continue
    target_is_aggregate "$target" && continue
    target_rel="$(target_source_rel "$target")"
    path_is_descendant "$target_rel" "$parent_rel" || continue
    printf '%s\n' "$target"
  done < <(backup_targets)
}

append_registered_subproject_excludes() {
  local parent="$1"
  local filter_file="$2"
  local parent_rel child child_rel relative
  local count=0

  parent_rel="$(target_source_rel "$parent")"
  while IFS= read -r child || [ -n "$child" ]; do
    [ -n "$child" ] || continue
    child_rel="$(target_source_rel "$child")"
    relative="${child_rel#"$parent_rel/"}"
    [ -n "$relative" ] || continue
    printf -- '- /%s/***\n' "$relative" >> "$filter_file"
    count=$((count + 1))
    log "Excluindo subprojeto cadastrado do ZIP pai: $relative/"
  done < <(registered_subprojects "$parent")

  [ "$count" -eq 0 ] || log "$count subprojeto(s) cadastrado(s) excluído(s) do backup pai."
}

backup_order_targets() {
  local target rel depth
  local -a normal=()
  local -a aggregate_lines=()
  local -a code=()

  while IFS= read -r target || [ -n "$target" ]; do
    [ -n "$target" ] || continue
    if ! target_is_aggregate "$target"; then
      normal+=("$target")
    elif target_is_code_aggregate "$target"; then
      code+=("$target")
    else
      rel="$(target_source_rel "$target")"
      depth="$(awk -F/ '{print NF}' <<<"$rel")"
      aggregate_lines+=("$depth"$'\t'"$target")
    fi
  done < <(backup_targets)

  [ "${#normal[@]}" -eq 0 ] || printf '%s\n' "${normal[@]}"
  if [ "${#aggregate_lines[@]}" -gt 0 ]; then
    printf '%s\n' "${aggregate_lines[@]}" | sort -t $'\t' -k1,1nr -k2,2 | cut -f2-
  fi
  [ "${#code[@]}" -eq 0 ] || printf '%s\n' "${code[@]}"
}

validate_projects() {
  local project project_dir archive_name source_rel logical_name alias alias_key owner
  local failed=0
  local -a aggregate_children=()
  declare -A logical_owner=()
  declare -A alias_owner=()

  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    project="$(normalize_target "$project")"

    if [[ "$project" = /* || "$project" = *".."* ]]; then
      log "ERRO: entrada inválida em $PROJECTS_FILE: $project"
      failed=1
      continue
    fi

    project_dir="$(project_path "$project")"
    archive_name="$(project_archive_name "$project")"
    source_rel="$(target_source_rel "$project")"

    if target_is_aggregate "$project"; then
      if ! target_is_code_aggregate "$project" && [ ! -d "$project_dir" ]; then
        log "ERRO: pasta do agregador configurado não existe: $project_dir"
        failed=1
      fi
      if [ -n "$source_rel" ]; then
        mapfile -t aggregate_children < <(aggregate_child_targets "$project")
        if [ "${#aggregate_children[@]}" -eq 0 ]; then
          log "ERRO: agregador sem projetos/agrupadores descendentes configurados: $project"
          failed=1
        fi
      fi
    else
      if [ ! -d "$project_dir" ]; then
        log "ERRO: projeto configurado não existe: $project_dir"
        failed=1
      fi

      logical_name="$(project_logical_name "$project")"
      alias_key="${logical_name,,}"
      owner="${logical_owner[$alias_key]:-}"
      if [ -n "$owner" ] && [ "$owner" != "$project" ]; then
        log "ERRO: nome lógico de projeto duplicado '$logical_name'."
        log "  Já cadastrado: $owner"
        log "  Duplicado:     $project"
        log "Nomes lógicos de projeto são chave única global, independentemente do projeto pai."
        failed=1
      else
        logical_owner["$alias_key"]="$project"
      fi
    fi

    while IFS= read -r alias || [ -n "$alias" ]; do
      [ -n "$alias" ] || continue
      alias_key="${alias,,}"
      owner="${alias_owner[$alias_key]:-}"
      if [ -n "$owner" ] && [ "$owner" != "$project" ]; then
        log "ERRO: alias de ZIP ambíguo '$alias.zip' entre '$owner' e '$project'."
        failed=1
      else
        alias_owner["$alias_key"]="$project"
      fi
    done < <(project_import_names "$project")
  done < <(backup_targets)

  [ "$failed" -eq 0 ]
}

project_for_zip() {
  local zip_name="$1"
  local zip_name_lower zip_stem zip_stem_lower
  local project alias alias_lower suffix first_suffix_char
  local best=""
  local best_name=""

  zip_name_lower="${zip_name,,}"
  [[ "$zip_name_lower" == *.zip ]] || {
    echo ""
    return 0
  }

  # Retira apenas a extensão final. Para projetos aninhados, aceita tanto o
  # nome lógico curto (exec-agent.zip) quanto o backup qualificado gerado pelo
  # manager (dev-automation--exec-agent.zip). O nome lógico é globalmente único.
  zip_stem="${zip_name:0:${#zip_name}-4}"
  zip_stem_lower="${zip_stem,,}"

  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue

    while IFS= read -r alias || [ -n "$alias" ]; do
      [ -n "$alias" ] || continue
      alias_lower="${alias,,}"

      # Aceita o nome exato ou sufixo iniciado por separador não alfanumérico,
      # preservando nomes de arquivos gerados pelo navegador/chat, por exemplo:
      #   exec-agent.zip
      #   exec-agent-incremental.zip
      #   dev-automation--exec-agent.zip
      #   dev-automation--exec-agent(2).zip
      if [[ "$zip_stem_lower" == "$alias_lower" ]]; then
        suffix=""
      elif [[ "$zip_stem_lower" == "$alias_lower"* ]]; then
        suffix="${zip_stem:${#alias}}"
        first_suffix_char="${suffix:0:1}"
        [[ -n "$first_suffix_char" && ! "$first_suffix_char" =~ [[:alnum:]] ]] || continue
      else
        continue
      fi

      if [ "${#alias}" -gt "${#best_name}" ]; then
        best="$project"
        best_name="$alias"
      fi
    done < <(project_import_names "$project")
  done < <(backup_targets)

  echo "$best"
}

project_update_scope() {
  local source_dir="$1"
  local rel
  local api=false web=false shared=false runtime=false

  while IFS= read -r -d '' rel; do
    case "$rel" in
      apps/api/tests/*|apps/api/.env.example|apps/web/tests/*|apps/web/.env.example)
        ;;
      apps/api/*)
        api=true; runtime=true ;;
      apps/web/*)
        web=true; runtime=true ;;
      deploy/local/*api*.sh)
        api=true; runtime=true ;;
      deploy/local/*web*.sh)
        web=true; runtime=true ;;
      deploy/local/setup.sh|deploy/local/start.sh|config/*|scripts/*)
        shared=true; runtime=true ;;
      deploy/remote/*|tests/*|docs/*|README|README.*|CHANGELOG|CHANGELOG.*|*.md|.gitignore|.gitattributes)
        ;;
      *)
        # Arquivo de runtime fora das árvores canônicas: por segurança trata
        # como compartilhado. Não reinicia por documentação/testes.
        shared=true; runtime=true ;;
    esac
  done < <(find "$source_dir" -type f -printf '%P\0' 2>/dev/null)

  if [ "$runtime" = false ]; then
    printf 'none\n'
  elif [ "$shared" = true ] || { [ "$api" = true ] && [ "$web" = true ]; }; then
    printf 'both\n'
  elif [ "$api" = true ]; then
    printf 'api\n'
  elif [ "$web" = true ]; then
    printf 'web\n'
  else
    printf 'both\n'
  fi
}

action_matches_update_scope() {
  local action="$1" scope="$2"
  case "$scope" in
    api)
      [[ "$action" == *api* || "$action" == "setup" || "$action" == "start" || "$action" == "run" ]] ;;
    web)
      [[ "$action" == *web* || "$action" == "setup" || "$action" == "start" || "$action" == "run" ]] ;;
    both)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

notify_running_project_update() {
  local project_dir="$1" scope="$2"
  local state_file request_file request_temp pid state_project_dir action signaled=0 stale=0

  [ "$scope" != "none" ] || {
    log "ATUALIZAÇÃO: somente arquivos sem efeito de runtime; nenhum restart necessário."
    return 0
  }
  [ -d "$RUNNING_PROJECTS_DIR" ] || {
    log "ATUALIZAÇÃO: $scope; nenhum comando local ativo registrado para reiniciar."
    return 0
  }

  while IFS= read -r -d '' state_file; do
    pid="$(awk -F= '$1=="PID" {print substr($0,5); exit}' "$state_file" 2>/dev/null || true)"
    state_project_dir="$(awk -F= '$1=="PROJECT_DIR" {print substr($0,13); exit}' "$state_file" 2>/dev/null || true)"
    action="$(awk -F= '$1=="ACTION" {print substr($0,8); exit}' "$state_file" 2>/dev/null || true)"

    if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f -- "$state_file" 2>/dev/null || true
      stale=$((stale + 1))
      continue
    fi
    [ "$state_project_dir" = "$project_dir" ] || continue
    action_matches_update_scope "$action" "$scope" || continue

    request_file="$state_file.request"
    request_temp="$request_file.tmp.$$"
    printf '%s\n' "$scope" > "$request_temp"
    mv -f -- "$request_temp" "$request_file"
    if kill -USR1 "$pid" 2>/dev/null; then
      signaled=$((signaled + 1))
      log "RESTART SOLICITADO: escopo=$scope ação=$action PID=$pid"
    else
      rm -f -- "$request_file" 2>/dev/null || true
    fi
  done < <(find "$RUNNING_PROJECTS_DIR" -maxdepth 1 -type f -name '*.state' -print0 2>/dev/null)

  if [ "$signaled" -eq 0 ]; then
    log "ATUALIZAÇÃO: $scope; projeto não estava rodando por comando global supervisionado. Nada foi iniciado à força."
  else
    log "ATUALIZAÇÃO: $scope; $signaled comando(s) ativo(s) sinalizado(s) após a importação completa."
  fi
  [ "$stale" -eq 0 ] || log "RUNTIME: removido(s) $stale registro(s) obsoleto(s)."
}

import_one_zip() {
  local zip_file="$1"
  local skip_stable="${2:-false}"
  local zip_name project archive_name logical_name project_dir temp_dir source_dir filtered_dir unzip_filter_file
  local total_files checked_files rel destination update_scope="none"
  local nested_zip nested_project nested_count=0 nested_index expected child_name
  local -a nested_zips=() nested_projects=() expected_children=()
  local -A nested_seen=() expected_targets=()

  zip_name="$(basename "$zip_file")"
  project="$(project_for_zip "$zip_name")"

  if [ -z "$project" ]; then
    log "Ignorando ZIP sem projeto/agregador configurado: $zip_name"
    return 0
  fi

  if [ "$skip_stable" != "true" ] && ! stable_file "$zip_file"; then
    log "ZIP ainda está sendo gravado: $zip_name"
    return 0
  fi

  taskbar_status unzip "$zip_name"
  archive_name="$(project_archive_name "$project")"
  logical_name=""
  if ! target_is_aggregate "$project"; then
    logical_name="$(project_logical_name "$project")"
  fi
  project_dir="$(project_path "$project")"
  temp_dir="$(mktemp -d "/tmp/auto-code-import-${archive_name}-XXXXXX")"

  line
  log "IMPORTAÇÃO INICIADA"
  log "ZIP:        $zip_file"
  log "Alvo:       $project"
  log "Destino:    $project_dir"
  log "Temporário: $temp_dir"

  if ! unzip -tq "$zip_file" >/dev/null 2>&1; then
    log "ERRO: ZIP inválido ou corrompido. O ZIP foi mantido."
    rm -rf -- "$temp_dir"
    return 1
  fi

  log "Extraindo ZIP para a pasta temporária..."
  if ! unzip -oq -- "$zip_file" -d "$temp_dir"; then
    log "ERRO: falha ao extrair. O ZIP foi mantido."
    rm -rf -- "$temp_dir"
    return 1
  fi

  if [ -d "$temp_dir/$archive_name" ]; then
    source_dir="$temp_dir/$archive_name"
    log "Raiz do ZIP identificada: $archive_name/"
  elif [ -n "$logical_name" ] && [ -d "$temp_dir/$logical_name" ]; then
    source_dir="$temp_dir/$logical_name"
    log "Raiz lógica do projeto identificada: $logical_name/"
  else
    source_dir="$temp_dir"
    log "ZIP sem pasta raiz do alvo; usando a raiz do ZIP."
  fi

  if target_is_aggregate "$project"; then
    mapfile -t expected_children < <(aggregate_child_targets "$project")
    for expected in "${expected_children[@]}"; do
      expected_targets["$expected"]=1
    done

    while IFS= read -r -d '' nested_zip; do
      child_name="$(basename -- "$nested_zip")"
      nested_project="$(project_for_zip "$child_name")"

      if [ -z "$nested_project" ] || [ -z "${expected_targets[$nested_project]+x}" ]; then
        log "ERRO: ZIP agregador contém filho não esperado: $(basename -- "$nested_zip")"
        log "ZIP agregador mantido: $zip_file"
        rm -rf -- "$temp_dir"
        return 1
      fi
      if [ -n "${nested_seen[$nested_project]+x}" ]; then
        log "ERRO: ZIP agregador contém mais de um ZIP para o mesmo alvo: $nested_project"
        log "ZIP agregador mantido: $zip_file"
        rm -rf -- "$temp_dir"
        return 1
      fi
      if ! unzip -tq "$nested_zip" >/dev/null 2>&1; then
        log "ERRO: ZIP filho inválido: $(basename -- "$nested_zip")"
        log "Nenhum ZIP filho foi importado; ZIP agregador mantido: $zip_file"
        rm -rf -- "$temp_dir"
        return 1
      fi

      nested_seen["$nested_project"]=1
      nested_zips+=("$nested_zip")
      nested_projects+=("$nested_project")
    done < <(find "$source_dir" -maxdepth 1 -type f -iname "*.zip" -print0 2>/dev/null)

    for expected in "${expected_children[@]}"; do
      if [ -z "${nested_seen[$expected]+x}" ]; then
        log "ERRO: ZIP agregador não contém o filho esperado: $(project_archive_name "$expected").zip"
        log "ZIP agregador mantido: $zip_file"
        rm -rf -- "$temp_dir"
        return 1
      fi
    done

    if find "$source_dir" -maxdepth 1 -type f ! -iname '*.zip' -print -quit | grep -q .; then
      log "ERRO: ZIP agregador deve conter somente ZIPs filhos configurados."
      log "ZIP agregador mantido: $zip_file"
      rm -rf -- "$temp_dir"
      return 1
    fi

    nested_count="${#nested_zips[@]}"
    [ "$nested_count" -gt 0 ] || {
      log "ERRO: ZIP agregador vazio. O ZIP foi mantido."
      rm -rf -- "$temp_dir"
      return 1
    }

    log "Todos os $nested_count ZIP(s) filho(s) foram validados antes da importação."
    for ((nested_index = 0; nested_index < nested_count; nested_index++)); do
      nested_zip="${nested_zips[$nested_index]}"
      nested_project="${nested_projects[$nested_index]}"
      log "ZIP filho [$((nested_index + 1))/$nested_count]: $(basename -- "$nested_zip") -> $nested_project"
      if ! import_one_zip "$nested_zip" true; then
        log "ERRO: falha ao importar ZIP filho. O ZIP agregador foi mantido: $zip_file"
        rm -rf -- "$temp_dir"
        return 1
      fi
    done

    rm -rf -- "$temp_dir"
    if ! rm -f -- "$zip_file" || [ -e "$zip_file" ]; then
      log "ERRO: filhos importados, mas o ZIP agregador não foi apagado: $zip_file"
      return 1
    fi
    log "$nested_count ZIP(s) filho(s) importado(s) e confirmado(s)."
    log "IMPORTAÇÃO DE AGREGADOR CONCLUÍDA: $project"
    soft_beep
    line
    return 0
  fi

  filtered_dir="$(mktemp -d "/tmp/auto-code-unzip-filtered-${archive_name}-XXXXXX")"
  unzip_filter_file="$(mktemp "/tmp/auto-code-unzip-filter-${archive_name}-XXXXXX")"
  make_project_rsync_filter \
    "$IGNORE_UNZIP_FILE" \
    "$project_dir" \
    "auto-code-manager.ignore-unzip" \
    "$unzip_filter_file"

  {
    echo "- **/config/local/***"
    echo "- **/config/remote/***"
    echo "- **/config/production/***"
  } >> "$unzip_filter_file"

  log "Protegendo no unzip: */config/local/**, */config/remote/** e */config/production/**"
  log "Aplicando regras de ignore-unzip..."
  if ! rsync -a --filter="merge $unzip_filter_file" -- "$source_dir/" "$filtered_dir/"; then
    log "ERRO: falha ao aplicar ignore-unzip. O ZIP foi mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"
    return 1
  fi

  if ! materialize_changed_protected_configs "$project" "$source_dir" "$filtered_dir"; then
    log "ERRO: falha ao comparar configs protegidos. O ZIP foi mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"
    return 1
  fi

  source_dir="$filtered_dir"
  total_files="$(find "$source_dir" -type f -printf '.' 2>/dev/null | wc -c)"
  if [ "$total_files" -eq 0 ]; then
    log "ERRO: nenhum arquivo foi extraído. O ZIP foi mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"
    return 1
  fi

  log "Arquivos diretos extraídos: $total_files"
  find "$source_dir" -type f -printf '  EXTRAÍDO: %P\n'

  log "Copiando arquivos diretos para o destino..."
  if ! rsync -a --itemize-changes -- "$source_dir/" "$project_dir/" | sed 's/^/  RSYNC: /'; then
    log "ERRO: falha ao copiar. O ZIP foi mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"
    return 1
  fi

  log "Conferindo arquivo por arquivo no destino..."
  checked_files=0
  while IFS= read -r -d '' rel; do
    destination="$project_dir/$rel"
    if [ ! -f "$destination" ]; then
      log "ERRO: arquivo não apareceu no destino: $destination"
      log "ZIP mantido: $zip_file"
      rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"
      return 1
    fi
    if ! cmp -s -- "$source_dir/$rel" "$destination"; then
      log "ERRO: arquivo no destino está diferente: $destination"
      log "ZIP mantido: $zip_file"
      rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"
      return 1
    fi
    checked_files=$((checked_files + 1))
    log "CONFIRMADO [$checked_files/$total_files]: $destination"
  done < <(find "$source_dir" -type f -printf '%P\0')

  if [ "$checked_files" -ne "$total_files" ]; then
    log "ERRO: conferidos $checked_files de $total_files arquivos. ZIP mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"
    return 1
  fi

  update_scope="$(project_update_scope "$source_dir")"
  log "Escopo de runtime detectado: $update_scope"
  rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"
  log "Apagando ZIP original somente após todas as confirmações..."
  if ! rm -f -- "$zip_file" || [ -e "$zip_file" ]; then
    log "ERRO: arquivos importados, mas o ZIP não foi apagado: $zip_file"
    return 1
  fi

  log "IMPORTAÇÃO CONCLUÍDA"
  log "Destino confirmado: $project_dir"
  log "ZIP apagado: $zip_file"
  notify_running_project_update "$project_dir" "$update_scope"
  soft_beep
  line
}

import_downloads() {
  local downloads zip_file
  local total index imported=0 failed=0
  local -a zip_files=()

  downloads="$(downloads_dir)"

  if [ -z "$downloads" ] || [ ! -d "$downloads" ]; then
    log "Downloads não encontrado."
    return 0
  fi

  log "Verificando Downloads: $downloads"

  # Captura todos os ZIPs existentes no início da rodada e os processa no mesmo
  # lote. Assim o monitor não volta para limpeza/backup/espera entre um ZIP e
  # outro. Um arquivo que chegar depois fica para a próxima rodada.
  while IFS= read -r -d '' zip_file; do
    zip_files+=("$zip_file")
  done < <(
    find "$downloads" \
      -maxdepth 1 \
      -type f \
      -iname "*.zip" \
      -print0 2>/dev/null | sort -z
  )

  total="${#zip_files[@]}"
  if [ "$total" -eq 0 ]; then
    log "Nenhum ZIP encontrado em Downloads nesta rodada."
    return 0
  fi

  log "LOTE DE DOWNLOADS: $total ZIP(s) serão processados em sequência antes de continuar o ciclo."

  for ((index = 0; index < total; index++)); do
    wait_if_paused
    zip_file="${zip_files[$index]}"
    log "LOTE [$((index + 1))/$total]: $(basename -- "$zip_file")"

    if import_one_zip "$zip_file"; then
      imported=$((imported + 1))
    else
      failed=$((failed + 1))
      log "Falha ao importar: $(basename -- "$zip_file")"
    fi
  done

  log "LOTE DE DOWNLOADS CONCLUÍDO: $imported sucesso(s), $failed falha(s), $total processado(s)."
  [ "$failed" -eq 0 ]
}

clean_zone() {
  taskbar_status clean "Zone.Identifier"
  log "Limpando Zone.Identifier em $CODE_ROOT"

  find "$CODE_ROOT" \
    -type f \
    -name "*:Zone.Identifier" \
    -delete 2>/dev/null ||
    true
}

make_rsync_filter() {
  local ignore_file="$1"
  local output="$2"
  local pattern
  local action
  local directory

  : > "$output"

  while IFS= read -r pattern || [ -n "$pattern" ]; do
    [ -n "$pattern" ] || continue

    action="-"

    if [[ "$pattern" == !* ]]; then
      action="+"
      pattern="${pattern:1}"
    fi

    if [[ "$pattern" == */ ]]; then
      directory="${pattern%/}"

      if [[ "$directory" == */* ]]; then
        echo "$action /$directory/***" >> "$output"
      else
        echo "$action $directory/***" >> "$output"
        echo "$action **/$directory/***" >> "$output"
      fi
    elif [[ "$pattern" == */* ]]; then
      echo "$action /$pattern" >> "$output"
    else
      echo "$action $pattern" >> "$output"
      echo "$action **/$pattern" >> "$output"
    fi
  done < <(clean_file "$ignore_file")

  echo "- *:Zone.Identifier" >> "$output"
  echo "- **/*:Zone.Identifier" >> "$output"
}

append_scoped_ignore_file() {
  local ignore_file="$1"
  local scope="$2"
  local output="$3"
  local pattern action directory base

  while IFS= read -r pattern || [ -n "$pattern" ]; do
    [ -n "$pattern" ] || continue

    action="-"
    if [[ "$pattern" == !* ]]; then
      action="+"
      pattern="${pattern:1}"
    fi

    # Barra inicial ancora a regra na raiz da pasta que contém o ignore.
    if [[ "$pattern" == /* ]]; then
      pattern="${pattern#/}"
      if [ -n "$scope" ]; then
        echo "$action /$scope/$pattern" >> "$output"
      else
        echo "$action /$pattern" >> "$output"
      fi
      continue
    fi

    base="${scope:+$scope/}"

    if [[ "$pattern" == */ ]]; then
      directory="${pattern%/}"
      echo "$action /$base$directory/***" >> "$output"
      echo "$action /${base}**/$directory/***" >> "$output"
    elif [[ "$pattern" == */* ]]; then
      echo "$action /$base$pattern" >> "$output"
    else
      echo "$action /$base$pattern" >> "$output"
      echo "$action /${base}**/$pattern" >> "$output"
    fi
  done < <(clean_file "$ignore_file")
}

make_project_rsync_filter() {
  local global_ignore_file="$1"
  local project_dir="$2"
  local ignore_filename="$3"
  local output="$4"
  local ignore_file scope count=0

  : > "$output"

  if [ -f "$global_ignore_file" ]; then
    make_rsync_filter "$global_ignore_file" "$output"
  fi

  while IFS= read -r -d '' ignore_file; do
    scope="${ignore_file#"$project_dir"/}"
    scope="${scope%/$ignore_filename}"
    [ "$scope" = "$ignore_filename" ] && scope=""

    log "Usando regras específicas: $ignore_file"
    append_scoped_ignore_file "$ignore_file" "$scope" "$output"
    count=$((count + 1))
  done < <(
    find "$project_dir" \
      -type f \
      -name "$ignore_filename" \
      -print0 2>/dev/null
  )

  if [ "$count" -eq 0 ]; then
    log "Sem arquivos $ignore_filename dentro de $project_dir"
  else
    log "$count arquivo(s) $ignore_filename reconhecido(s) dentro de $project_dir"
  fi

  # Os próprios arquivos de configuração devem continuar no backup, salvo se
  # alguma regra explícita disser o contrário.
}

expand_configured_path() {
  local configured_path="$1"

  configured_path="${configured_path/#\~\//$HOME/}"
  configured_path="${configured_path/#\$CODE_ROOT\//$CODE_ROOT/}"
  configured_path="${configured_path/#CODE_ROOT\//$CODE_ROOT/}"

  if [[ "$configured_path" != /* ]]; then
    configured_path="$CODE_ROOT/$configured_path"
  fi

  printf '%s\n' "$configured_path"
}

configured_sql_zip_folders() {
  local raw_line folder

  [ -f "$FOLDER_SQL_ZIP_FILE" ] || return 0

  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    raw_line="${raw_line%$'\r'}"
    raw_line="${raw_line%%#*}"
    raw_line="$(printf '%s' "$raw_line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$raw_line" ] || continue

    folder="$(expand_configured_path "$raw_line")"
    printf '%s\n' "$folder"
  done < "$FOLDER_SQL_ZIP_FILE"
}

zip_sql_folder() {
  local folder="$1"
  local stamp final_zip temp_dir temp_zip sql_file sql_name
  local -a sql_files=()
  local -a sql_names=()

  if [ ! -d "$folder" ]; then
    log "Pasta SQL ainda não existe: $folder"
    return 0
  fi

  while IFS= read -r -d '' sql_file; do
    if stable_file "$sql_file"; then
      sql_files+=("$sql_file")
    else
      log "SQL ainda está sendo gravado: $sql_file"
    fi
  done < <(
    find "$folder" \
      -maxdepth 1 \
      -type f \
      -iname '*.sql' \
      ! -name '*:Zone.Identifier' \
      -print0 2>/dev/null
  )

  [ "${#sql_files[@]}" -gt 0 ] || return 0

  taskbar_status zip "$(basename -- "$folder")"
  stamp="$(date '+%Y%m%d-%H%M')"
  final_zip="$folder/$stamp.zip"
  temp_dir="$(mktemp -d '/tmp/auto-code-folder-sql-zip-XXXXXX')"
  temp_zip="$temp_dir/$stamp.zip"

  if [ -f "$final_zip" ]; then
    if ! unzip -tq "$final_zip" >/dev/null 2>&1; then
      log "ERRO: ZIP existente inválido; SQLs mantidos: $final_zip"
      rm -rf -- "$temp_dir"
      return 1
    fi
    cp -f -- "$final_zip" "$temp_zip" || {
      log "ERRO: não foi possível preparar o ZIP existente: $final_zip"
      rm -rf -- "$temp_dir"
      return 1
    }
  fi

  for sql_file in "${sql_files[@]}"; do
    sql_name="$(basename -- "$sql_file")"
    sql_names+=("$sql_name")
    cp -f -- "$sql_file" "$temp_dir/$sql_name" || {
      log "ERRO: não foi possível preparar o SQL: $sql_file"
      rm -rf -- "$temp_dir"
      return 1
    }
  done

  (
    cd "$temp_dir" || exit 1
    zip -q "$temp_zip" -- "${sql_names[@]}"
  ) || {
    log "ERRO: falha ao gerar ZIP de SQLs em $folder; SQLs mantidos."
    rm -rf -- "$temp_dir"
    return 1
  }

  if [ ! -s "$temp_zip" ] || ! unzip -tq "$temp_zip" >/dev/null 2>&1; then
    log "ERRO: validação do ZIP de SQLs falhou; SQLs mantidos: $folder"
    rm -rf -- "$temp_dir"
    return 1
  fi

  if ! mv -f -- "$temp_zip" "$final_zip"; then
    log "ERRO: não foi possível instalar o ZIP final; SQLs mantidos: $final_zip"
    rm -rf -- "$temp_dir"
    return 1
  fi

  for sql_file in "${sql_files[@]}"; do
    if ! rm -f -- "$sql_file" || [ -e "$sql_file" ]; then
      log "ERRO: ZIP válido, mas o SQL não foi apagado: $sql_file"
      rm -rf -- "$temp_dir"
      return 1
    fi
  done

  rm -rf -- "$temp_dir"
  log "OK SQL ZIP: $final_zip (${#sql_files[@]} arquivo(s)); SQLs apagados."
  return 0
}

zip_configured_sql_folders() {
  local folder failed=0

  while IFS= read -r folder || [ -n "$folder" ]; do
    [ -n "$folder" ] || continue
    wait_if_paused
    zip_sql_folder "$folder" || failed=1
  done < <(configured_sql_zip_folders)

  return "$failed"
}

sanitize_backup_config_passwords() {
  local backup_dir="$1"

  python3 - "$backup_dir" <<'PY_SANITIZE'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
placeholder = "********"
config_extensions = {".env", ".ini", ".conf", ".cfg", ".properties"}
config_names = {"env", ".env", "config", "settings"}
secret_key = re.compile(
    r"(?:^|_)(?:PASSWORD|PASSWD|PWD|SECRET|TOKEN|API_KEY|ACCESS_KEY|PRIVATE_KEY)(?:$|_)",
    re.IGNORECASE,
)
assignment = re.compile(
    r"^(?P<prefix>\s*(?:export\s+)?(?P<key>[A-Za-z_][A-Za-z0-9_.-]*)\s*=\s*)(?P<value>.*?)(?P<ending>\r?\n?)$"
)
url_credentials = re.compile(
    r"(?P<prefix>\b[A-Za-z][A-Za-z0-9+.-]*://[^\s:/@]+:)(?P<password>[^\s@]*)(?P<suffix>@)"
)
changed_files = 0
changed_values = 0


def is_config_file(path: Path) -> bool:
    parts = path.relative_to(root).parts
    if not any(part.lower() == "config" for part in parts[:-1]):
        return False

    name = path.name.lower()
    suffix = path.suffix.lower()
    return (
        suffix in config_extensions
        or name in config_names
        or name.startswith(".env.")
        or name.endswith(".env")
    )


def mask_value(value: str) -> str:
    stripped = value.strip()
    if not stripped:
        return value

    leading = value[: len(value) - len(value.lstrip())]
    trailing = value[len(value.rstrip()) :]
    core = stripped

    comment = ""
    comment_match = re.match(r"^(.*?)(\s+[;#][^\r\n]*)$", core)
    if comment_match:
        core, comment = comment_match.groups()
        core = core.rstrip()

    if len(core) >= 2 and core[0] == core[-1] and core[0] in {"'", '"'}:
        masked = f"{core[0]}{placeholder}{core[-1]}"
    else:
        masked = placeholder

    return f"{leading}{masked}{comment}{trailing}"


for path in root.rglob("*"):
    if not path.is_file() or not is_config_file(path):
        continue

    try:
        raw = path.read_bytes()
    except OSError:
        continue

    if b"\x00" in raw:
        continue

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        continue

    output = []
    file_changed = False

    for line in text.splitlines(keepends=True):
        match = assignment.match(line)
        if not match:
            output.append(line)
            continue

        key = match.group("key")
        value = match.group("value")

        if secret_key.search(key):
            new_value = mask_value(value)
        else:
            new_value = url_credentials.sub(
                lambda item: f"{item.group('prefix')}{placeholder}{item.group('suffix')}",
                value,
            )

        if new_value != value:
            file_changed = True
            changed_values += 1

        output.append(f"{match.group('prefix')}{new_value}{match.group('ending')}")

    if file_changed:
        path.write_text("".join(output), encoding="utf-8", newline="")
        changed_files += 1

print(f"{changed_files}:{changed_values}")
PY_SANITIZE
}

protected_config_relpath() {
  case "$1" in
    */config/local/*|*/config/remote/*|*/config/production/*) return 0 ;;
    *) return 1 ;;
  esac
}

protected_config_baseline_dir() {
  local project="$1"
  printf '%s/%s\n' "$PROTECTED_CONFIG_BASELINES_DIR" "$(project_archive_name "$project")"
}

save_protected_config_baseline() {
  local project="$1"
  local sanitized_root="$2"
  local baseline_dir rel destination

  baseline_dir="$(protected_config_baseline_dir "$project")"
  rm -rf -- "$baseline_dir"
  mkdir -p -- "$baseline_dir"

  while IFS= read -r -d '' rel; do
    protected_config_relpath "$rel" || continue
    destination="$baseline_dir/$rel"
    mkdir -p -- "$(dirname -- "$destination")"
    cp -p -- "$sanitized_root/$rel" "$destination"
  done < <(find "$sanitized_root" -type f -printf '%P\0')
}

canonical_external_relpath() {
  local rel="$1"

  while [[ "$rel" == *.external ]]; do
    rel="${rel%.external}"
  done

  printf '%s.external\n' "$rel"
}

materialize_changed_protected_configs() {
  local project="$1"
  local source_root="$2"
  local filtered_root="$3"
  local baseline_dir rel baseline_rel baseline external_rel external changed=0 unchanged=0

  baseline_dir="$(protected_config_baseline_dir "$project")"

  while IFS= read -r -d '' rel; do
    protected_config_relpath "$rel" || continue

    external_rel="$(canonical_external_relpath "$rel")"
    baseline_rel="$rel"
    if [[ "$rel" == *.external ]]; then
      baseline_rel="$external_rel"
    fi
    baseline="$baseline_dir/$baseline_rel"

    if [ -f "$baseline" ] && cmp -s -- "$source_root/$rel" "$baseline"; then
      unchanged=$((unchanged + 1))
      continue
    fi

    external="$filtered_root/$external_rel"
    mkdir -p -- "$(dirname -- "$external")"
    cp -p -- "$source_root/$rel" "$external"
    changed=$((changed + 1))
    log "ENV EXTERNAL: $rel -> $external_rel"
  done < <(find "$source_root" -type f -printf '%P\0')

  log "ENV protegidos: $changed alterado(s)/novo(s), $unchanged sem mudança."
}

backup_project() {
  local project="$1"
  local project_dir archive_name temp_dir temp_zip final_zip filter_file=""
  local child child_name child_zip child_count
  local sanitize_result sanitized_files sanitized_values
  local -a children=()

  project_dir="$(project_path "$project")"
  archive_name="$(project_archive_name "$project")"

  if [ ! -d "$project_dir" ]; then
    log "ERRO: alvo não existe: $project_dir"
    rm -f -- "$(project_archive_path "$project")"
    return 1
  fi

  taskbar_status backup "$archive_name"
  temp_dir="$(mktemp -d "/tmp/auto-code-backup-${archive_name}-XXXXXX")"
  temp_zip="/tmp/${archive_name}-backup-$$.zip"
  final_zip="$(project_archive_path "$project")"

  log "Gerando backup: $project -> $final_zip"

  if target_is_aggregate "$project"; then
    mapfile -t children < <(aggregate_child_targets "$project")
    child_count="${#children[@]}"
    if [ "$child_count" -eq 0 ]; then
      log "ERRO: agregador sem filhos configurados: $project"
      rm -rf -- "$temp_dir" "$temp_zip"
      return 1
    fi

    for child in "${children[@]}"; do
      child_name="$(project_archive_name "$child")"
      child_zip="$(project_archive_path "$child")"
      if [ ! -s "$child_zip" ] || ! unzip -tq "$child_zip" >/dev/null 2>&1; then
        log "ERRO: ZIP filho ausente ou inválido para o agregador: $child_zip"
        rm -rf -- "$temp_dir" "$temp_zip"
        return 1
      fi
      cp -f -- "$child_zip" "$temp_dir/$child_name.zip" || {
        log "ERRO ao incluir ZIP filho no agregador: $child_zip"
        rm -rf -- "$temp_dir" "$temp_zip"
        return 1
      }
    done
    log "Agregador explícito preparado com $child_count ZIP(s), sem duplicar ramos cobertos."
  else
    filter_file="$(mktemp "/tmp/auto-code-filter-${archive_name}-XXXXXX")"
    make_project_rsync_filter \
      "$IGNORE_ZIP_FILE" \
      "$project_dir" \
      "auto-code-manager.ignore-zip" \
      "$filter_file"
    append_registered_subproject_excludes "$project" "$filter_file"

    if ! rsync -a --filter="merge $filter_file" "$project_dir/" "$temp_dir/"; then
      log "ERRO no rsync do projeto: $project"
      rm -rf -- "$temp_dir" "$filter_file" "$temp_zip"
      return 1
    fi

    if ! sanitize_result="$(sanitize_backup_config_passwords "$temp_dir")"; then
      log "ERRO ao sanitizar senhas dos configs no backup: $project"
      rm -rf -- "$temp_dir" "$filter_file" "$temp_zip"
      return 1
    fi
    sanitized_files="${sanitize_result%%:*}"
    sanitized_values="${sanitize_result##*:}"
    if [ "${sanitized_values:-0}" -gt 0 ]; then
      log "Configs sanitizados no ZIP: ${sanitized_values} senha(s) em ${sanitized_files} arquivo(s)."
    fi

    if ! save_protected_config_baseline "$project" "$temp_dir"; then
      log "ERRO ao salvar referência sanitizada dos configs protegidos: $project"
      rm -rf -- "$temp_dir" "$filter_file" "$temp_zip"
      return 1
    fi
    log "Referência sanitizada dos configs protegidos atualizada."
  fi

  if ! (cd "$temp_dir" && zip -qry "$temp_zip" .); then
    log "ERRO ao compactar alvo: $project"
    rm -rf -- "$temp_dir" ${filter_file:+"$filter_file"} "$temp_zip"
    return 1
  fi
  if [ ! -s "$temp_zip" ] || ! unzip -tq "$temp_zip" >/dev/null 2>&1; then
    log "ERRO: validação do backup falhou: $project"
    rm -rf -- "$temp_dir" ${filter_file:+"$filter_file"} "$temp_zip"
    return 1
  fi

  mv -f -- "$temp_zip" "$final_zip"
  rm -rf -- "$temp_dir"
  [ -z "$filter_file" ] || rm -f -- "$filter_file"
  log "OK backup: $final_zip"
  return 0
}

clean_unmanaged_backup_zips() {
  local zip_file expected project managed

  log "Limpando ZIPs de backup fora dos alvos explicitamente configurados em $CODE_ROOT"
  while IFS= read -r -d '' zip_file; do
    wait_if_paused
    managed=false
    while IFS= read -r project || [ -n "$project" ]; do
      [ -n "$project" ] || continue
      expected="$(project_archive_path "$project")"
      if [ "$zip_file" = "$expected" ]; then
        managed=true
        break
      fi
    done < <(backup_targets)

    if [ "$managed" = false ]; then
      log "Removendo ZIP não configurado no .projects: $zip_file"
      rm -f -- "$zip_file" || log "ERRO ao remover ZIP não configurado: $zip_file"
    fi
  done < <(find "$CODE_ROOT" -mindepth 1 -maxdepth 3 -type f -iname "*.zip" -print0 2>/dev/null)
}

backup_all() {
  local project
  local failed=0
  local -a projects=()

  if ! validate_backup_ignore_zip; then
    log "ERRO: rodada de backup cancelada antes de qualquer compactação."
    return 1
  fi

  mapfile -t projects < <(backup_order_targets)
  for project in "${projects[@]}"; do
    [ -n "$project" ] || continue
    wait_if_paused
    backup_project "$project" || failed=1
  done

  if [ "$failed" -ne 0 ]; then
    log "ERRO: um ou mais alvos configurados falharam nesta rodada."
    return 1
  fi

  log "Rodada completa: somente projetos/agregadores explicitamente presentes no .projects foram gerados."
  return 0
}


watch_root_projects() {
  local project parent project_dir
  declare -A seen=()

  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    target_is_aggregate "$project" && continue

    parent="$(registered_parent_project "$project")"
    [ -z "$parent" ] || continue

    project_dir="$(project_path "$project")"
    if [ -z "${seen[$project_dir]+x}" ]; then
      printf '%s\n' "$project_dir"
      seen["$project_dir"]=1
    fi
  done < <(backup_targets)
}


light_config_signature() {
  local path
  for path in "$ENV_FILE" "$PROJECTS_FILE" "$IGNORE_ZIP_FILE" "$FOLDER_SQL_ZIP_FILE"; do
    if [ -e "$path" ]; then
      stat -c '%n\t%Y\t%s' -- "$path" 2>/dev/null || true
    else
      printf '%s\tmissing\n' "$path"
    fi
  done
}

build_light_watch_plan() {
  local project root child child_root excluded
  local -a projects=()

  mkdir -p "$STATE_DIR"
  LIGHT_WATCH_PLAN="$STATE_DIR/light-watch-plan.tsv"
  : > "$LIGHT_WATCH_PLAN"

  mapfile -t projects < <(backup_targets)
  for project in "${projects[@]}"; do
    [ -n "$project" ] || continue
    target_is_aggregate "$project" && continue
    root="$(project_path "$project")"
    [ -d "$root" ] || continue

    printf 'P\t%s\t%s\n' "$project" "$root" >> "$LIGHT_WATCH_PLAN"

    # Mesmas subárvores pesadas já ignoradas pelo backup/.gitignore.
    while IFS= read -r excluded || [ -n "$excluded" ]; do
      [ -n "$excluded" ] || continue
      printf 'X\t%s\t%s\n' "$project" "$excluded" >> "$LIGHT_WATCH_PLAN"
    done < <(watch_excluded_directories "$root")

    # Se um alvo configurado está dentro de outro, o pai não percorre o filho:
    # cada subprojeto é medido uma vez e recebe o próprio backup.
    for child in "${projects[@]}"; do
      [ "$child" = "$project" ] && continue
      [ -n "$child" ] || continue
      target_is_aggregate "$child" && continue
      child_root="$(project_path "$child")"
      if [ "$child_root" != "$root" ] && path_is_within_absolute "$child_root" "$root"; then
        printf 'X\t%s\t%s\n' "$project" "$child_root" >> "$LIGHT_WATCH_PLAN"
      fi
    done
  done
}

light_scan_states() {
  [ -n "$LIGHT_WATCH_PLAN" ] && [ -f "$LIGHT_WATCH_PLAN" ] || build_light_watch_plan

  python3 - "$LIGHT_WATCH_PLAN" "$IGNORE_ZIP_FILE" <<'PY_LIGHT_SCAN'
import fnmatch
import os
import sys

plan_file, ignore_file = sys.argv[1:3]
projects = []
excluded = {}

with open(plan_file, 'r', encoding='utf-8', errors='replace') as fh:
    for raw in fh:
        parts = raw.rstrip('\n').split('\t', 2)
        if len(parts) != 3:
            continue
        kind, project, path = parts
        path = os.path.abspath(path)
        if kind == 'P':
            projects.append((project, path))
            excluded.setdefault(project, set())
        elif kind == 'X':
            excluded.setdefault(project, set()).add(path)

file_rules = []
try:
    with open(ignore_file, 'r', encoding='utf-8', errors='replace') as fh:
        for raw in fh:
            line = raw.rstrip('\r\n')
            line = line.split('#', 1)[0].strip()
            if not line or line.endswith('/'):
                continue
            negated = line.startswith('!')
            if negated:
                line = line[1:]
            line = line.lstrip('/')
            if line:
                file_rules.append((negated, line))
except OSError:
    pass

def ignored_file(rel, name):
    ignored = False
    for negated, pattern in file_rules:
        if '/' in pattern:
            match = fnmatch.fnmatchcase(rel, pattern)
        else:
            match = fnmatch.fnmatchcase(name, pattern)
        if match:
            ignored = not negated
    return ignored

for project, root in projects:
    max_mtime = 0
    entries = 0
    total_size = 0
    max_dir_mtime = 0
    dir_count = 0
    max_gitignore_mtime = 0
    gitignore_count = 0
    gitignore_size = 0
    excluded_roots = excluded.get(project, set())

    try:
        st = os.stat(root, follow_symlinks=False)
        max_mtime = max(max_mtime, st.st_mtime_ns)
        max_dir_mtime = max(max_dir_mtime, st.st_mtime_ns)
        dir_count += 1
    except OSError:
        print(f'{project}\tmissing\tmissing\tmissing')
        continue

    for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
        kept = []
        for name in dirs:
            full = os.path.abspath(os.path.join(current, name))
            if full in excluded_roots:
                continue
            kept.append(name)
            try:
                st = os.stat(full, follow_symlinks=False)
                max_mtime = max(max_mtime, st.st_mtime_ns)
                max_dir_mtime = max(max_dir_mtime, st.st_mtime_ns)
                entries += 1
                dir_count += 1
            except OSError:
                pass
        dirs[:] = kept

        for name in files:
            full = os.path.join(current, name)
            rel = os.path.relpath(full, root).replace(os.sep, '/')
            if ignored_file(rel, name):
                continue
            try:
                st = os.stat(full, follow_symlinks=False)
            except OSError:
                continue
            max_mtime = max(max_mtime, st.st_mtime_ns)
            entries += 1
            total_size += st.st_size
            if name == '.gitignore':
                max_gitignore_mtime = max(max_gitignore_mtime, st.st_mtime_ns)
                gitignore_count += 1
                gitignore_size += st.st_size

    state_sig = f'{max_mtime}:{entries}:{total_size}'
    tree_sig = f'{max_dir_mtime}:{dir_count}'
    ignore_sig = f'{max_gitignore_mtime}:{gitignore_count}:{gitignore_size}'
    print(f'{project}\t{state_sig}\t{tree_sig}\t{ignore_sig}')
PY_LIGHT_SCAN
}

initialize_light_monitor() {
  local project signature tree_signature ignore_signature

  build_light_watch_plan
  LIGHT_SIGNATURES=()
  LIGHT_TREE_SIGNATURES=()
  LIGHT_IGNORE_SIGNATURES=()
  while IFS=$'\t' read -r project signature tree_signature ignore_signature || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    LIGHT_SIGNATURES["$project"]="$signature"
    LIGHT_TREE_SIGNATURES["$project"]="$tree_signature"
    LIGHT_IGNORE_SIGNATURES["$project"]="$ignore_signature"
  done < <(light_scan_states)

  LIGHT_CONFIG_SIGNATURE="$(light_config_signature)"
  ACTIVE_MONITOR_MODE="light"
  log "Monitor leve ativo: sem inotify; verifica somente metadados dos projetos a cada ${LIGHT_SCAN_INTERVAL}s e poda .gitignore/ignore-zip."
}

light_refresh_if_config_changed() {
  local signature
  signature="$(light_config_signature)"
  [ "$signature" = "$LIGHT_CONFIG_SIGNATURE" ] && return 0

  load_env
  validate_timers
  validate_projects || return 1
  validate_backup_ignore_zip || return 1
  clean_unmanaged_backup_zips || true
  initialize_light_monitor
  mark_all_projects_dirty
  zip_configured_sql_folders || true
  return 0
}

light_process_downloads_and_sql() {
  local downloads folder

  downloads="$(downloads_dir)"
  if [ -n "$downloads" ] && [ -d "$downloads" ] && \
     find "$downloads" -maxdepth 1 -type f -iname '*.zip' -print -quit 2>/dev/null | grep -q .; then
    run_stage downloads "DOWNLOAD / IMPORTAÇÃO" "ZIP detectado no monitor leve; processa somente o lote presente em Downloads." \
      import_downloads || true
  fi

  while IFS= read -r folder || [ -n "$folder" ]; do
    [ -n "$folder" ] || continue
    [ -d "$folder" ] || continue
    if find "$folder" -maxdepth 1 -type f -iname '*.sql' ! -name '*:Zone.Identifier' -print -quit 2>/dev/null | grep -q .; then
      run_stage sql "SQL → ZIP" "SQL detectado no monitor leve; compacta somente a pasta afetada." \
        zip_sql_folder "$folder" || true
    fi
  done < <(configured_sql_zip_folders)
}

light_scan_cycle() {
  local project signature tree_signature ignore_signature old old_tree old_ignore
  local plan_changed=false

  light_refresh_if_config_changed || return 1
  light_process_downloads_and_sql

  while IFS=$'\t' read -r project signature tree_signature ignore_signature || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    old="${LIGHT_SIGNATURES[$project]-}"
    old_tree="${LIGHT_TREE_SIGNATURES[$project]-}"
    old_ignore="${LIGHT_IGNORE_SIGNATURES[$project]-}"

    if [ -n "$old" ] && [ "$old" != "$signature" ]; then
      mark_backup_dirty "$project"
    fi
    if { [ -n "$old_tree" ] && [ "$old_tree" != "$tree_signature" ]; } || \
       { [ -n "$old_ignore" ] && [ "$old_ignore" != "$ignore_signature" ]; }; then
      plan_changed=true
    fi

    LIGHT_SIGNATURES["$project"]="$signature"
    LIGHT_TREE_SIGNATURES["$project"]="$tree_signature"
    LIGHT_IGNORE_SIGNATURES["$project"]="$ignore_signature"
  done < <(light_scan_states)

  # Só refaz a poda quando a estrutura de diretórios ou algum .gitignore mudou.
  # Edição comum de código não custa uma reconstrução do plano.
  if [ "$plan_changed" = true ]; then
    build_light_watch_plan
  fi
  return 0
}

start_change_monitor() {
  case "${AUTO_CODE_MONITOR_MODE:-light}" in
    light)
      initialize_light_monitor
      ;;
    inotify)
      start_backup_watcher || return 1
      ACTIVE_MONITOR_MODE="inotify"
      ;;
    auto)
      if start_backup_watcher; then
        ACTIVE_MONITOR_MODE="inotify"
      else
        LOG_CONTEXT=wait log "Inotify indisponível; usando monitor leve sem aumentar fs.inotify.max_user_instances."
        initialize_light_monitor
      fi
      ;;
    *)
      log "ERRO: AUTO_CODE_MONITOR_MODE deve ser light, inotify ou auto. Valor: ${AUTO_CODE_MONITOR_MODE:-}"
      return 1
      ;;
  esac
}

build_inotify_exclude_regex() {
  # Apenas regras de ARQUIVO são enviadas ao --exclude. Diretórios ignorados
  # são removidos da própria árvore de watches com @path, reduzindo drasticamente
  # o número de watches em .venv/node_modules/.git etc.
  python3 - "$IGNORE_ZIP_FILE" <<'PY_INOTIFY_REGEX'
import re
import sys

path = sys.argv[1]
patterns = []


def glob_to_ere(value: str) -> str:
    out = []
    for ch in value:
        if ch == '*':
            out.append('[^/]*')
        elif ch == '?':
            out.append('[^/]')
        else:
            out.append(re.escape(ch))
    return ''.join(out)

with open(path, 'r', encoding='utf-8', errors='replace') as fh:
    for raw in fh:
        line = raw.rstrip('\r\n')
        line = line.split('#', 1)[0].strip()
        if not line or line.startswith('!'):
            continue
        if line.endswith('/'):
            continue
        if 'Zone.Identifier' in line:
            # O evento precisa chegar para que o sidecar seja apagado sem scan.
            continue
        if line.startswith('/'):
            line = line[1:]
        if not line:
            continue
        patterns.append('(^|/)' + glob_to_ere(line) + '$')

print('|'.join(patterns))
PY_INOTIFY_REGEX
}

build_inotify_directory_regex() {
  python3 - "$IGNORE_ZIP_FILE" <<'PY_INOTIFY_DIR_REGEX'
import re
import sys

path = sys.argv[1]
patterns = []


def glob_to_ere(value: str) -> str:
    out = []
    for ch in value:
        if ch == '*':
            out.append('[^/]*')
        elif ch == '?':
            out.append('[^/]')
        else:
            out.append(re.escape(ch))
    return ''.join(out)

with open(path, 'r', encoding='utf-8', errors='replace') as fh:
    for raw in fh:
        line = raw.rstrip('\r\n')
        line = line.split('#', 1)[0].strip()
        if not line or line.startswith('!') or not line.endswith('/'):
            continue
        line = line[:-1]
        if line.startswith('/'):
            line = line[1:]
        if not line:
            continue
        patterns.append('(^|/)' + glob_to_ere(line) + '(/|$)')

print('|'.join(patterns))
PY_INOTIFY_DIR_REGEX
}

watch_excluded_directories() {
  local root="$1"
  python3 - "$root" "$IGNORE_ZIP_FILE" <<'PY_WATCH_EXCLUDES'
import fnmatch
import os
import subprocess
import sys

root = os.path.abspath(sys.argv[1])
ignore_file = sys.argv[2]
basename_rules = []
path_rules = []
git_ignored_dirs = set()

with open(ignore_file, 'r', encoding='utf-8', errors='replace') as fh:
    for raw in fh:
        line = raw.rstrip('\r\n')
        line = line.split('#', 1)[0].strip()
        if not line or line.startswith('!') or not line.endswith('/'):
            continue
        line = line[:-1].lstrip('/')
        if not line:
            continue
        if '/' in line:
            path_rules.append(line)
        else:
            basename_rules.append(line)

# O Git resolve .gitignore aninhado, excludes globais e regras com !. Com
# --directory ele devolve a raiz das subárvores ignoradas, permitindo podá-las
# antes do os.walk entrar nelas.
try:
    inside = subprocess.run(
        ['git', '-C', root, 'rev-parse', '--is-inside-work-tree'],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if inside.returncode == 0:
        ignored = subprocess.run(
            ['git', '-C', root, 'ls-files', '-z', '--others', '--ignored',
             '--exclude-standard', '--directory', '--', '.'],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if ignored.returncode == 0:
            for raw in ignored.stdout.split(b'\0'):
                if not raw.endswith(b'/'):
                    continue
                rel = raw[:-1].decode('utf-8', errors='surrogateescape')
                if rel:
                    git_ignored_dirs.add(rel)
except OSError:
    pass

for current, dirs, _files in os.walk(root, topdown=True, followlinks=False):
    kept = []
    for name in dirs:
        full = os.path.join(current, name)
        rel = os.path.relpath(full, root).replace(os.sep, '/')
        ignored = rel in git_ignored_dirs
        if not ignored:
            ignored = any(fnmatch.fnmatchcase(name, pat) for pat in basename_rules)
        if not ignored:
            ignored = any(fnmatch.fnmatchcase(rel, pat) for pat in path_rules)
        if ignored:
            print(full)
        else:
            kept.append(name)
    dirs[:] = kept
PY_WATCH_EXCLUDES
}

path_is_git_ignored() {
  local project_dir="$1" event_path="$2"

  command -v git >/dev/null 2>&1 || return 1
  git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$project_dir" check-ignore -q -- "$event_path" 2>/dev/null
}

event_owner_project() {
  local event_path="$1"
  local project project_dir
  local best=""
  local best_len=-1

  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    target_is_aggregate "$project" && continue
    project_dir="$(project_path "$project")"

    if [ "$event_path" = "$project_dir" ] || [[ "$event_path" == "$project_dir/"* ]]; then
      if [ "${#project_dir}" -gt "$best_len" ]; then
        best="$project"
        best_len="${#project_dir}"
      fi
    fi
  done < <(backup_targets)

  printf '%s\n' "$best"
}

mark_backup_dirty() {
  local project="$1"
  local event_path="${2:-}"

  [ -n "$project" ] || return 0
  if [ -z "${DIRTY_BACKUP_TARGETS[$project]+x}" ]; then
    LOG_CONTEXT=backup log "Alteração detectada; backup pendente: $project"
  fi
  DIRTY_BACKUP_TARGETS["$project"]=1
  LAST_SOURCE_CHANGE="$(date +%s)"

  if [ "$event_path" = "$PROJECTS_FILE" ] || [ "$event_path" = "$IGNORE_ZIP_FILE" ]; then
    WATCH_RELOAD_REQUESTED=true
  fi
}

dirty_backup_count() {
  printf '%s\n' "${#DIRTY_BACKUP_TARGETS[@]}"
}

aggregate_depends_on_project() {
  local aggregate="$1"
  local project="$2"
  local aggregate_rel project_rel

  target_is_aggregate "$aggregate" || return 1
  target_is_code_aggregate "$aggregate" && return 0

  aggregate_rel="$(target_source_rel "$aggregate")"
  project_rel="$(target_source_rel "$project")"
  path_is_descendant "$project_rel" "$aggregate_rel"
}

backup_dirty_targets() {
  local project aggregate target
  local failed=0
  local -a dirty_projects=()
  local -a ordered=()
  declare -A selected_aggregates=()

  [ "${#DIRTY_BACKUP_TARGETS[@]}" -gt 0 ] || return 0

  if ! validate_backup_ignore_zip; then
    log "ERRO: backup inteligente cancelado antes de qualquer compactação."
    return 1
  fi

  # Preserva a ordem declarada no .projects para os projetos normais.
  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    target_is_aggregate "$project" && continue
    [ -n "${DIRTY_BACKUP_TARGETS[$project]+x}" ] || continue
    dirty_projects+=("$project")
  done < <(backup_targets)

  [ "${#dirty_projects[@]}" -gt 0 ] || {
    DIRTY_BACKUP_TARGETS=()
    return 0
  }

  for project in "${dirty_projects[@]}"; do
    wait_if_paused
    if ! backup_project "$project"; then
      failed=1
    fi
  done

  # Nunca reconstrói agregadores a partir de um filho cujo backup falhou.
  if [ "$failed" -ne 0 ]; then
    log "ERRO: projeto alterado falhou; agregadores dependentes não foram atualizados."
    return 1
  fi

  while IFS= read -r aggregate || [ -n "$aggregate" ]; do
    [ -n "$aggregate" ] || continue
    target_is_aggregate "$aggregate" || continue
    for project in "${dirty_projects[@]}"; do
      if aggregate_depends_on_project "$aggregate" "$project"; then
        selected_aggregates["$aggregate"]=1
        break
      fi
    done
  done < <(backup_targets)

  mapfile -t ordered < <(backup_order_targets)
  for target in "${ordered[@]}"; do
    target_is_aggregate "$target" || continue
    [ -n "${selected_aggregates[$target]+x}" ] || continue
    wait_if_paused
    if ! backup_project "$target"; then
      failed=1
      break
    fi
  done

  if [ "$failed" -ne 0 ]; then
    log "ERRO: agregador dependente falhou; projeto permanece marcado para nova tentativa."
    return 1
  fi

  for project in "${dirty_projects[@]}"; do
    unset 'DIRTY_BACKUP_TARGETS[$project]'
  done

  LAST_SOURCE_CHANGE=0
  log "Backup inteligente concluído: ${#dirty_projects[@]} projeto(s) alterado(s) e somente agregadores dependentes."
  return 0
}

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

  # O watcher principal usa -r. Para Downloads e pastas SQL que não pertencem
  # a um projeto, excluímos os subdiretórios para manter o watch efetivamente
  # não recursivo e barato.
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

  # Downloads: entra no MESMO fluxo de eventos. Se estiver fora dos projetos,
  # é observado somente no primeiro nível (onde o navegador grava os ZIPs).
  downloads="$(downloads_dir)"
  if [ -n "$downloads" ] && [ -d "$downloads" ] && ! path_is_covered_by_roots "$downloads" "${roots[@]}"; then
    append_nonrecursive_watch_root "$downloads"
    roots+=("$downloads")
    watched_aux=$((watched_aux + 1))
  fi

  # Pastas SQL: normalmente já estão dentro de projetos. Só adiciona um root
  # auxiliar quando a pasta configurada estiver fora de todos eles.
  while IFS= read -r sql_folder || [ -n "$sql_folder" ]; do
    [ -n "$sql_folder" ] || continue
    [ -d "$sql_folder" ] || continue
    if ! path_is_covered_by_roots "$sql_folder" "${roots[@]}"; then
      append_nonrecursive_watch_root "$sql_folder"
      roots+=("$sql_folder")
      watched_aux=$((watched_aux + 1))
    fi
  done < <(configured_sql_zip_folders)

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
  downloads="$(downloads_dir)"
  [ -n "$downloads" ] || return 1
  path_is_within_absolute "$event_path" "$downloads" || return 1
  [ "$(dirname -- "$event_path")" = "$downloads" ] || return 1
  [[ "${event_path,,}" == *.zip ]]
}

sql_folder_for_event() {
  local event_path="$1"
  local folder
  while IFS= read -r folder || [ -n "$folder" ]; do
    [ -n "$folder" ] || continue
    [ "$(dirname -- "$event_path")" = "$folder" ] || continue
    printf '%s\n' "$folder"
    return 0
  done < <(configured_sql_zip_folders)
  return 1
}

mark_all_projects_dirty() {
  local project
  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    target_is_aggregate "$project" && continue
    DIRTY_BACKUP_TARGETS["$project"]=1
  done < <(backup_targets)
  LAST_SOURCE_CHANGE="$(date +%s)"
  LOG_CONTEXT=backup log "Configuração estrutural alterada; projetos registrados marcados para reconciliação após ${BACKUP_EVERY}s de silêncio."
}

handle_watch_event() {
  local events="$1"
  local event_path="$2"
  local owner sql_folder=""

  [ -n "$event_path" ] || return 0

  # Zone.Identifier: limpeza por evento, sem find periódico.
  if [[ "$event_path" == *":Zone.Identifier" ]]; then
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
    elif [ "$event_path" = "$FOLDER_SQL_ZIP_FILE" ]; then
      WATCH_RELOAD_REQUESTED=true
    fi
  fi

  # ZIP novo em Downloads: importa diretamente pelo evento de gravação/rename.
  # CLOSE_WRITE/MOVED_TO já garantem que o produtor fechou o arquivo; a própria
  # importação ainda valida o ZIP antes de tocar no projeto.
  if event_finished_write "$events" && path_is_download_zip "$event_path" && [ -f "$event_path" ]; then
    run_stage downloads "DOWNLOAD / IMPORTAÇÃO" "ZIP detectado pelo filesystem; importa somente este arquivo, sem varrer Downloads." \
      import_one_zip "$event_path" true || true
    return 0
  fi

  # SQL novo: compacta somente a pasta que recebeu o arquivo.
  if event_finished_write "$events" && [[ "${event_path,,}" == *.sql ]] && [ -f "$event_path" ]; then
    sql_folder="$(sql_folder_for_event "$event_path" || true)"
    if [ -n "$sql_folder" ]; then
      run_stage sql "SQL → ZIP" "SQL detectado pelo filesystem; compacta somente a pasta afetada." \
        zip_sql_folder "$sql_folder" || true
    fi
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

  # Uma nova pasta SQL configurada pode já conter SQLs anteriores à inclusão.
  zip_configured_sql_folders || true
  return 0
}

backup_watcher_alive() {
  [ -n "${WATCH_PID:-}" ] && kill -0 "$WATCH_PID" 2>/dev/null
}

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

trap stop INT TERM
trap tui_cleanup EXIT
trap tui_on_resize WINCH

ensure_files
load_env
ensure_downloads_dir
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

if [ "${1:-}" = "--import-downloads-once" ]; then
  if [ ! -d "$CODE_ROOT" ]; then
    echo "ERRO: diretório não existe: $CODE_ROOT" >&2
    exit 1
  fi

  if ! validate_projects; then
    echo "ERRO: corrija $PROJECTS_FILE antes de importar." >&2
    exit 1
  fi

  if import_downloads; then
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
  LOG_CONTEXT=wait log "CODE_ROOT=$CODE_ROOT · Downloads=$(downloads_dir) · modo=${AUTO_CODE_MONITOR_MODE:-light}."
else
  line
  echo "Auto Code Manager - $SCRIPT_VERSION"
  line
  echo "CODE_ROOT:     $CODE_ROOT"
  echo "Downloads:     $(downloads_dir)"
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

run_stage zone "LIMPEZA ZONE.IDENTIFIER INICIAL" "Remove resíduos antigos uma única vez; novos sidecars são apagados por evento." clean_zone || true
run_stage downloads "DOWNLOADS INICIAIS" "Importa somente ZIPs que já estavam em Downloads antes do watcher iniciar; depois cada ZIP chega por evento." import_downloads || true
run_stage sql "SQLs INICIAIS" "Compacta somente SQLs que já existiam antes do watcher iniciar; depois cada pasta é acionada por evento." zip_configured_sql_folders || true

taskbar_status idle "Aguardando eventos"
if [ "$ACTIVE_MONITOR_MODE" = "light" ]; then
  LOG_CONTEXT=wait log "IDLE leve: sem inotify; somente metadados dos projetos configurados a cada ${LIGHT_SCAN_INTERVAL}s."
else
  LOG_CONTEXT=wait log "IDLE event-driven: aguardando inotify; nenhuma varredura periódica de projetos, Downloads, SQL ou Zone.Identifier."
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
