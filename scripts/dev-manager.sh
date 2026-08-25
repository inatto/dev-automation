#!/usr/bin/env bash
# Executa o Auto Code Manager diretamente, sem sessão intermediária.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
AUTO_MANAGER="${DEV_MANAGER_AUTO_MANAGER:-$PROJECT_ROOT/scripts/auto-code-manager.sh}"
COMMAND_INSTALLER="${DEV_MANAGER_INSTALL_COMMANDS:-$PROJECT_ROOT/deploy/local/install-commands.sh}"
DESKTOPS_SCRIPT="${DEV_MANAGER_DESKTOPS_SCRIPT:-$PROJECT_ROOT/scripts/desktops.sh}"
LRDP_SCRIPT="${DEV_MANAGER_LRDP_SCRIPT:-$PROJECT_ROOT/apps/lrdp/lrdp}"
DEV_STATUS_SCRIPT="${DEV_MANAGER_DEV_STATUS_SCRIPT:-$PROJECT_ROOT/scripts/dev-status.sh}"
G512_RGB_SCRIPT="${DEV_MANAGER_G512_RGB_SCRIPT:-$PROJECT_ROOT/scripts/g512-rgb.sh}"
MONITOR_STATE_DIR="${AUTO_CODE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dev-automation}"
MONITOR_LOCK_FILE="$MONITOR_STATE_DIR/auto-code-manager.monitor.lock"
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
  dev-manager lrdp         Abre o LRDP Control Center fullscreen
  dev-manager git-crypt    Executa MANUALMENTE git-crypt unlock com a chave padrão
  dev-manager g512         Mostra/controla o auxiliar RGB do Logitech G512
  dev-manager status       Verifica se há um monitor ativo
  dev-manager stop         Encerra o monitor ativo e limpa watchers/lock presos
  dev-manager help         Mostra esta ajuda

O monitor não cria sessão em segundo plano. Para encerrar, pressione Ctrl+C
ou Q na TUI. De qualquer outro terminal, use: dev-manager stop
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

ensure_g512_rgb() {
  if [[ ! -f "$G512_RGB_SCRIPT" ]]; then
    printf '[dev-manager] AVISO: auxiliar G512 ausente: %s\n' "$G512_RGB_SCRIPT" >&2
    return 0
  fi

  [[ -x "$G512_RGB_SCRIPT" ]] || chmod +x "$G512_RGB_SCRIPT"
  printf '[dev-manager] garantindo auxiliar RGB G512 independente...\n'
  if "$G512_RGB_SCRIPT" ensure; then
    printf '[dev-manager] auxiliar RGB G512 verificado.\n'
  else
    # RGB nunca impede o monitor principal de abrir.
    printf '[dev-manager] AVISO: não foi possível garantir o G512; dev-manager seguirá normalmente.\n' >&2
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

monitor_pid_from_lock() {
  local pid cmdline
  [[ -r "$MONITOR_LOCK_FILE" ]] || return 1
  pid="$(head -n 1 "$MONITOR_LOCK_FILE" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  [[ "$cmdline" == *"auto-code-manager.sh"* ]] || return 1
  printf '%s\n' "$pid"
}

monitor_lock_is_busy() {
  local fd
  [[ -e "$MONITOR_LOCK_FILE" ]] || return 1
  command -v flock >/dev/null 2>&1 || return 1
  exec {fd}>>"$MONITOR_LOCK_FILE"
  if flock -n "$fd"; then
    flock -u "$fd" 2>/dev/null || true
    eval "exec ${fd}>&-" 2>/dev/null || true
    return 1
  fi
  eval "exec ${fd}>&-" 2>/dev/null || true
  return 0
}

lock_holder_pids() {
  local proc pid fd target uid_line current_uid
  [[ -e "$MONITOR_LOCK_FILE" ]] || return 0
  current_uid="$(id -u)"
  for proc in /proc/[0-9]*; do
    pid="${proc##*/}"
    [[ "$pid" != "$$" ]] || continue
    uid_line="$(awk '/^Uid:/{print $2; exit}' "$proc/status" 2>/dev/null || true)"
    [[ "$uid_line" == "$current_uid" ]] || continue
    for fd in "$proc"/fd/*; do
      [[ -e "$fd" || -L "$fd" ]] || continue
      target="$(readlink -f -- "$fd" 2>/dev/null || true)"
      if [[ "$target" == "$MONITOR_LOCK_FILE" ]]; then
        printf '%s\n' "$pid"
        break
      fi
    done
  done
}

monitor_pid_from_lock_holder() {
  local pid cmdline
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ "$cmdline" == *"auto-code-manager.sh"* ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
  done < <(lock_holder_pids)
  return 1
}

active_monitor_pid() {
  local pid
  pid="$(monitor_pid_from_lock || true)"
  if [[ -n "$pid" ]]; then
    printf '%s\n' "$pid"
    return 0
  fi
  monitor_pid_from_lock_holder
}

signal_monitor_pid() {
  local pid="$1" sig="$2" pgid
  kill -0 "$pid" 2>/dev/null || return 0
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "$pgid" =~ ^[0-9]+$ && "$pgid" == "$pid" ]]; then
    kill "-$sig" -- "-$pgid" 2>/dev/null || true
  else
    kill "-$sig" "$pid" 2>/dev/null || true
  fi
}

wait_monitor_pid() {
  local pid="$1" attempts="${2:-20}" i
  for ((i=0; i<attempts; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

stop_lock_holders() {
  local holder
  local -a holders=()
  monitor_lock_is_busy || return 0
  mapfile -t holders < <(lock_holder_pids | sort -u)
  for holder in "${holders[@]}"; do
    [[ "$holder" =~ ^[0-9]+$ ]] || continue
    kill -TERM "$holder" 2>/dev/null || true
  done
  sleep 0.3
  for holder in "${holders[@]}"; do
    [[ "$holder" =~ ^[0-9]+$ ]] || continue
    kill -0 "$holder" 2>/dev/null || continue
    kill -KILL "$holder" 2>/dev/null || true
  done
}

stop_manager() {
  local pid
  mkdir -p -- "$MONITOR_STATE_DIR"
  pid="$(active_monitor_pid || true)"

  if [[ -n "$pid" ]]; then
    printf '[dev-manager] encerrando Auto Code Manager PID %s...\n' "$pid"
    signal_monitor_pid "$pid" INT
    if ! wait_monitor_pid "$pid" 20; then
      printf '[dev-manager] PID %s não respondeu a SIGINT; enviando SIGTERM...\n' "$pid" >&2
      signal_monitor_pid "$pid" TERM
      if ! wait_monitor_pid "$pid" 10; then
        printf '[dev-manager] PID %s ainda vivo; enviando SIGKILL.\n' "$pid" >&2
        signal_monitor_pid "$pid" KILL
        wait_monitor_pid "$pid" 5 || true
      fi
    fi
  fi

  # Versões antigas podiam deixar um processo auxiliar (principalmente o
  # indicador dev-status) com o FD do flock herdado. Mata SOMENTE processos do
  # próprio usuário que ainda mantêm exatamente este arquivo de lock aberto.
  stop_lock_holders

  if monitor_lock_is_busy; then
    printf '[dev-manager] ERRO: o lock continua ocupado: %s\n' "$MONITOR_LOCK_FILE" >&2
    return 1
  fi

  rm -f -- "$MONITOR_LOCK_FILE"
  printf '[dev-manager] Auto Code Manager parado.\n'
}

repair_orphan_monitor_lock() {
  local pid
  pid="$(active_monitor_pid || true)"
  [[ -z "$pid" ]] || return 1
  monitor_lock_is_busy || {
    rm -f -- "$MONITOR_LOCK_FILE"
    return 0
  }

  printf '[dev-manager] lock órfão detectado; limpando processo auxiliar legado...\n' >&2
  stop_lock_holders
  if monitor_lock_is_busy; then
    return 1
  fi
  rm -f -- "$MONITOR_LOCK_FILE"
  return 0
}

status_manager() {
  local pid recorded_pid=""
  pid="$(active_monitor_pid || true)"
  if [[ -n "$pid" ]]; then
    printf '[dev-manager] monitor ativo: PID %s\n' "$pid"
  elif monitor_lock_is_busy; then
    recorded_pid="$(head -n 1 "$MONITOR_LOCK_FILE" 2>/dev/null || true)"
    printf '[dev-manager] lock órfão/legado ocupado%s: %s\n' \
      "${recorded_pid:+ (PID gravado $recorded_pid)}" "$MONITOR_LOCK_FILE"
  else
    [[ ! -e "$MONITOR_LOCK_FILE" ]] || rm -f -- "$MONITOR_LOCK_FILE"
    printf '[dev-manager] nenhum monitor ativo.\n'
  fi
}


[[ -f "$AUTO_MANAGER" ]] || fail "script não encontrado: $AUTO_MANAGER"
[[ -x "$AUTO_MANAGER" ]] || chmod +x "$AUTO_MANAGER"

action="${1:-start}"
case "$action" in
  start|run)
    shift || true
    active_pid="$(active_monitor_pid || true)"
    if [[ -n "$active_pid" ]]; then
      printf '[dev-manager] ERRO: já existe um Auto Code Manager ativo (PID %s).\n' "$active_pid" >&2
      printf '[dev-manager] Para encerrar: dev-manager stop\n' >&2
      exit 3
    fi
    if monitor_lock_is_busy && ! repair_orphan_monitor_lock; then
      printf '[dev-manager] ERRO: não foi possível limpar o lock órfão. Execute: dev-manager stop\n' >&2
      exit 3
    fi
    # O dev-manager é também o ponto de autorreparo dos comandos locais.
    # Reinstala/valida wrappers e executáveis antes de iniciar o monitor para
    # que um round-trip de ZIP nunca deixe ~/.local/bin apontando para scripts
    # sem permissão de execução.
    refresh_global_commands
    printf '[dev-manager] executando monitor em primeiro plano; para parar, pressione Ctrl+C.\n'
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
  lrdp|rdp)
    shift || true
    [[ -f "$LRDP_SCRIPT" ]] || fail "LRDP Control Center não encontrado: $LRDP_SCRIPT"
    [[ -x "$LRDP_SCRIPT" ]] || chmod +x "$LRDP_SCRIPT"
    exec "$LRDP_SCRIPT" "$@"
    ;;
  git-crypt|gitcrypt|config-crypt|security-config)
    shift || true
    exec "$AUTO_MANAGER" --git-crypt-audit "$@"
    ;;
  g512|g512-rgb)
    shift || true
    [[ -f "$G512_RGB_SCRIPT" ]] || fail "auxiliar G512 não encontrado: $G512_RGB_SCRIPT"
    [[ -x "$G512_RGB_SCRIPT" ]] || chmod +x "$G512_RGB_SCRIPT"
    exec "$G512_RGB_SCRIPT" "${1:-status}" "${@:2}"
    ;;
  status)
    status_manager
    ;;
  stop)
    stop_manager
    ;;
  attach|restart)
    fail "a ação '$action' foi removida porque o monitor roda em primeiro plano. Use 'dev-manager' e encerre com Ctrl+C/Q ou 'dev-manager stop'."
    ;;
  help|-h|--help)
    show_help
    ;;
  *)
    fail "ação inválida: $action (use 'dev-manager help')"
    ;;
esac
