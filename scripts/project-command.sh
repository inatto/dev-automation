#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CLEAR_TERMINAL="$SCRIPT_DIR/clear-terminal.sh"
AUTO_MANAGER="${DEV_AUTOMATION_AUTO_MANAGER:-$SCRIPT_DIR/auto-code-manager.sh}"
STATE_DIR="${AUTO_CODE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dev-automation}"
RUNNING_PROJECTS_DIR="$STATE_DIR/running-projects"

PROJECT_NAME="${1:-}"
PROJECT_DIR="${2:-}"
DEPLOY_MODE="${3:-local}"
shift 3 || true
ACTION="${1:-setup}"
if (($# > 0)); then
  shift
fi
ARGS=("$@")

if [[ "${DEV_AUTOMATION_SKIP_CLEAR:-0}" != "1" && -f "$CLEAR_TERMINAL" ]]; then
  bash "$CLEAR_TERMINAL"
fi

fail() {
  printf '[%s] ERRO: %s\n' "${PROJECT_NAME:-project}" "$*" >&2
  exit 1
}

play_error_sound() {
  [[ "${DEV_AUTOMATION_ERROR_SOUND_ENABLED:-1}" == "1" ]] || return 0
  [[ -x "$AUTO_MANAGER" || -f "$AUTO_MANAGER" ]] || return 0
  bash "$AUTO_MANAGER" --error-sound >/dev/null 2>&1 || true
}

[[ -n "$PROJECT_NAME" ]] || fail "nome do projeto não informado"
[[ -n "$PROJECT_DIR" ]] || fail "diretório do projeto não informado"
[[ "$DEPLOY_MODE" == "local" || "$DEPLOY_MODE" == "remote" ]] || fail "modo de deploy inválido: $DEPLOY_MODE"
[[ -d "$PROJECT_DIR" ]] || fail "projeto configurado não existe: $PROJECT_DIR"
[[ "$ACTION" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || fail "ação inválida: $ACTION"

SCRIPT_PATH="$PROJECT_DIR/deploy/$DEPLOY_MODE/$ACTION.sh"
[[ -f "$SCRIPT_PATH" ]] || fail "script não encontrado: $SCRIPT_PATH"

printf '[%s] executando: ./deploy/%s/%s.sh%s\n' \
  "$PROJECT_NAME" "$DEPLOY_MODE" "$ACTION" "${ARGS[*]:+ ${ARGS[*]}}"
cd "$PROJECT_DIR"

# Remoto continua execução simples: nunca é reiniciado por um ZIP local.
if [[ "$DEPLOY_MODE" == "remote" ]]; then
  bash "$SCRIPT_PATH" "${ARGS[@]}"
  status=$?
  if ((status != 0)); then
    printf '[%s] ERRO: comando terminou com código %d\n' "$PROJECT_NAME" "$status" >&2
    play_error_sound
  fi
  exit "$status"
fi

mkdir -p -- "$RUNNING_PROJECTS_DIR"
STATE_FILE="$RUNNING_PROJECTS_DIR/$$.state"
REQUEST_FILE="$STATE_FILE.request"
CHILD_PID=""
API_PID=""
WEB_PID=""
RESTART_REQUESTED=0
RESTART_SCOPE="both"
STOP_REQUESTED=0
SUPERVISION_MODE="single"
API_SCRIPT=""
WEB_SCRIPT=""

can_split_canonical_action() {
  local api_name web_name ref refs
  [[ "$ACTION" == "setup" || "$ACTION" == "start" ]] || return 1
  API_SCRIPT="$PROJECT_DIR/deploy/local/${ACTION}-api.sh"
  WEB_SCRIPT="$PROJECT_DIR/deploy/local/${ACTION}-web.sh"
  [[ -f "$API_SCRIPT" && -f "$WEB_SCRIPT" ]] || return 1

  api_name="$(basename -- "$API_SCRIPT")"
  web_name="$(basename -- "$WEB_SCRIPT")"
  grep -Fq "$api_name" "$SCRIPT_PATH" || return 1
  grep -Fq "$web_name" "$SCRIPT_PATH" || return 1
  grep -Eq 'wait[[:space:]]+-n' "$SCRIPT_PATH" || return 1

  # Só divide orquestradores canônicos que referenciam os dois scripts de
  # camada e nenhum terceiro .sh. Se houver worker/preparo extra, preserva o
  # setup/start agregado original em vez de adivinhar comportamento.
  refs="$(grep -oE '[A-Za-z0-9._-]+\.sh' "$SCRIPT_PATH" 2>/dev/null | sort -u || true)"
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    [[ "$ref" == "$api_name" || "$ref" == "$web_name" ]] || return 1
  done <<< "$refs"

  return 0
}

if can_split_canonical_action; then
  SUPERVISION_MODE="split"
  printf '[%s] supervisão por camada ativa: API e Web independentes.\n' "$PROJECT_NAME"
fi

write_state() {
  local temp="$STATE_FILE.tmp.$$"
  {
    printf 'PID=%s\n' "$$"
    printf 'PROJECT_NAME=%s\n' "$PROJECT_NAME"
    printf 'PROJECT_DIR=%s\n' "$PROJECT_DIR"
    printf 'DEPLOY_MODE=%s\n' "$DEPLOY_MODE"
    printf 'ACTION=%s\n' "$ACTION"
    printf 'MODE=%s\n' "$SUPERVISION_MODE"
    printf 'CHILD_PID=%s\n' "${CHILD_PID:-}"
    printf 'API_PID=%s\n' "${API_PID:-}"
    printf 'WEB_PID=%s\n' "${WEB_PID:-}"
  } > "$temp"
  mv -f -- "$temp" "$STATE_FILE"
}

stop_pid() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null || true
}

start_api() {
  bash "$API_SCRIPT" "${ARGS[@]}" &
  API_PID=$!
  write_state
}

start_web() {
  bash "$WEB_SCRIPT" "${ARGS[@]}" &
  WEB_PID=$!
  write_state
}

read_restart_scope() {
  local scope=""
  scope="$(head -n 1 "$REQUEST_FILE" 2>/dev/null || true)"
  rm -f -- "$REQUEST_FILE" 2>/dev/null || true
  case "$scope" in api|web|both) printf '%s\n' "$scope" ;; *) printf 'both\n' ;; esac
}

on_restart() {
  RESTART_SCOPE="$(read_restart_scope)"
  RESTART_REQUESTED=1
  printf '\n[%s] ZIP concluído; reinício solicitado: %s.\n' "$PROJECT_NAME" "$RESTART_SCOPE"

  if [[ "$SUPERVISION_MODE" == "split" ]]; then
    case "$RESTART_SCOPE" in
      api) stop_pid "$API_PID" ;;
      web) stop_pid "$WEB_PID" ;;
      both) stop_pid "$API_PID"; stop_pid "$WEB_PID" ;;
    esac
  else
    stop_pid "$CHILD_PID"
  fi
}

on_stop() {
  STOP_REQUESTED=1
  if [[ "$SUPERVISION_MODE" == "split" ]]; then
    stop_pid "$API_PID"
    stop_pid "$WEB_PID"
  else
    stop_pid "$CHILD_PID"
  fi
}

cleanup() {
  rm -f -- "$STATE_FILE" "$STATE_FILE.tmp.$$" "$REQUEST_FILE" "$REQUEST_FILE.tmp."* 2>/dev/null || true
}

trap on_restart USR1
trap on_stop INT TERM
trap cleanup EXIT
write_state

if [[ "$SUPERVISION_MODE" == "split" ]]; then
  start_api
  start_web

  while true; do
    RESTART_REQUESTED=0
    wait -n "$API_PID" "$WEB_PID"
    status=$?

    if ((STOP_REQUESTED == 1)); then
      exit 130
    fi

    if ((RESTART_REQUESTED == 1)); then
      case "$RESTART_SCOPE" in
        api)
          wait "$API_PID" 2>/dev/null || true
          API_PID=""
          start_api
          ;;
        web)
          wait "$WEB_PID" 2>/dev/null || true
          WEB_PID=""
          start_web
          ;;
        both)
          wait "$API_PID" 2>/dev/null || true
          wait "$WEB_PID" 2>/dev/null || true
          API_PID=""
          WEB_PID=""
          start_api
          start_web
          ;;
      esac
      printf '[%s] reinício concluído: %s.\n' "$PROJECT_NAME" "$RESTART_SCOPE"
      continue
    fi

    # Um serviço terminar faz o orquestrador canônico terminar também; mantém o
    # mesmo contrato e garante aviso sonoro mesmo se a saída inesperada for 0.
    stop_pid "$API_PID"
    stop_pid "$WEB_PID"
    printf '[%s] ERRO: uma camada local encerrou inesperadamente (código %d).\n' "$PROJECT_NAME" "$status" >&2
    play_error_sound
    ((status == 0)) && status=1
    exit "$status"
  done
fi

while true; do
  RESTART_REQUESTED=0
  bash "$SCRIPT_PATH" "${ARGS[@]}" &
  CHILD_PID=$!
  write_state

  wait "$CHILD_PID"
  status=$?
  CHILD_PID=""
  write_state

  if ((STOP_REQUESTED == 1)); then
    exit 130
  fi

  if ((RESTART_REQUESTED == 1)); then
    printf '[%s] reiniciando uma única vez: ./deploy/%s/%s.sh\n' "$PROJECT_NAME" "$DEPLOY_MODE" "$ACTION"
    continue
  fi

  if ((status != 0)); then
    printf '[%s] ERRO: comando terminou com código %d\n' "$PROJECT_NAME" "$status" >&2
    play_error_sound
  fi
  exit "$status"
done
