#!/usr/bin/env bash
# Contexto: configuração, estado global e validações


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
DEV_STATUS_SCRIPT="$PROJECT_ROOT/scripts/dev-status.sh"
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

