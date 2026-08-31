#!/usr/bin/env bash
# Supervisor AUTO genérico para comandos globais do Dev Automation.

set -uo pipefail

COMMAND_NAME="${1:-}"
SOURCE_FILE="${2:-}"
WATCH_DIR="${3:-}"
RESTART_ON_DESCENDANT="${4:-0}"
shift 4 || true
ARGS=("$@")

STATE_DIR="${AUTO_CODE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dev-automation}"
RUNNING_PROJECTS_DIR="$STATE_DIR/running-projects"

fail() { printf '[%s-auto] ERRO: %s\n' "${COMMAND_NAME:-global}" "$*" >&2; exit 1; }

[[ -n "$COMMAND_NAME" ]] || fail "comando não informado"
if [[ "$SOURCE_FILE" == */* ]]; then
  [[ -f "$SOURCE_FILE" ]] || fail "fonte não encontrada: $SOURCE_FILE"
  RUN_COMMAND=("$SOURCE_FILE")
else
  RESOLVED_COMMAND="$(command -v -- "$SOURCE_FILE" 2>/dev/null || true)"
  [[ -n "$RESOLVED_COMMAND" ]] || fail "comando global não encontrado no PATH: $SOURCE_FILE"
  RUN_COMMAND=("$SOURCE_FILE")
fi
[[ -d "$WATCH_DIR" ]] || fail "pasta monitorada não encontrada: $WATCH_DIR"
[[ "$RESTART_ON_DESCENDANT" == "0" || "$RESTART_ON_DESCENDANT" == "1" ]] || fail "RESTART_ON_DESCENDANT inválido"

mkdir -p -- "$RUNNING_PROJECTS_DIR"
STATE_FILE="$RUNNING_PROJECTS_DIR/$$.state"
REQUEST_FILE="$STATE_FILE.request"
CHILD_PID=""
RESTART_REQUESTED=0
STOP_REQUESTED=0

write_state() {
  local temp="$STATE_FILE.tmp.$$"
  {
    printf 'PID=%s\n' "$$"
    printf 'PROJECT_NAME=%s-auto\n' "$COMMAND_NAME"
    printf 'PROJECT_DIR=%s\n' "$WATCH_DIR"
    printf 'DEPLOY_MODE=global\n'
    printf 'ACTION=%s\n' "$COMMAND_NAME"
    printf 'AUTO_MODE=1\n'
    printf 'MODE=global-command\n'
    printf 'GLOBAL_COMMAND=1\n'
    printf 'RESTART_ON_DESCENDANT=%s\n' "$RESTART_ON_DESCENDANT"
    if [[ "$COMMAND_NAME" == "dev-manager" ]]; then
      printf 'DEFER_RESTART=1\n'
    else
      printf 'DEFER_RESTART=0\n'
    fi
    printf 'SOURCE_FILE=%s\n' "$SOURCE_FILE"
    printf 'CHILD_PID=%s\n' "${CHILD_PID:-}"
  } > "$temp"
  mv -f -- "$temp" "$STATE_FILE"
}

stop_child() {
  local pid="${CHILD_PID:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  kill -INT "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null || true
}

stop_dev_manager_runtime() {
  [[ "$COMMAND_NAME" == "dev-manager" ]] || return 0
  local manager_script="$WATCH_DIR/scripts/dev-manager.sh"
  [[ -f "$manager_script" ]] || return 0
  # A TUI é só a frente do Auto Code Manager. Ao reiniciar, matar apenas a TUI
  # pode deixar o monitor/lock ativo e a próxima execução morre com código 3.
  # Use a rotina oficial de parada para encerrar o monitor e liberar o lock.
  bash "$manager_script" stop >/dev/null 2>&1 || true
}

on_restart() {
  RESTART_REQUESTED=1
  rm -f -- "$REQUEST_FILE" 2>/dev/null || true
  printf '\n[%s-auto] ZIP aplicado; reinício automático solicitado.\n' "$COMMAND_NAME"
  stop_child
  stop_dev_manager_runtime
}

on_stop() {
  STOP_REQUESTED=1
  stop_child
  stop_dev_manager_runtime
}

cleanup() {
  rm -f -- "$STATE_FILE" "$STATE_FILE.tmp.$$" "$REQUEST_FILE" "$REQUEST_FILE.tmp."* 2>/dev/null || true
}

trap on_restart USR1
trap on_stop INT TERM
trap cleanup EXIT
write_state

printf '[%s-auto] AUTO ativo; pasta monitorada: %s\n' "$COMMAND_NAME" "$WATCH_DIR"
if [[ "$RESTART_ON_DESCENDANT" == "1" ]]; then
  printf '[%s-auto] atualizações de subprojetos também disparam reinício.\n' "$COMMAND_NAME"
fi

while true; do
  RESTART_REQUESTED=0
  # Interfaces interativas supervisionadas precisam continuar ligadas ao
  # terminal real. Em shell não interativo, um comando iniciado com `&` pode
  # receber stdin de /dev/null e abrir sem aceitar a navegação pelo teclado.
  if [[ -r /dev/tty ]]; then
    "${RUN_COMMAND[@]}" "${ARGS[@]}" </dev/tty &
  else
    "${RUN_COMMAND[@]}" "${ARGS[@]}" &
  fi
  CHILD_PID=$!
  write_state

  wait "$CHILD_PID"
  status=$?
  CHILD_PID=""
  write_state

  (( STOP_REQUESTED == 0 )) || exit 130

  if (( RESTART_REQUESTED == 1 )); then
    printf '[%s-auto] reiniciando após atualização confirmada.\n' "$COMMAND_NAME"
    continue
  fi

  printf '[%s-auto] comando terminou com código %d; aguardando ZIP correspondente.\n' "$COMMAND_NAME" "$status"
  while (( RESTART_REQUESTED == 0 && STOP_REQUESTED == 0 )); do
    sleep 86400 &
    idle_pid=$!
    wait "$idle_pid" 2>/dev/null || true
  done
  (( STOP_REQUESTED == 0 )) || exit 130
  printf '[%s-auto] novo ZIP confirmado; executando novamente.\n' "$COMMAND_NAME"
done
