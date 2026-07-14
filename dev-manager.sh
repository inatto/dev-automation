#!/usr/bin/env bash

set -euo pipefail

SESSION="dev"

require_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "Erro: tmux não está instalado."
    echo "Execute uma vez:"
    echo "  /home/daniel/Code/sind-infra/deploy/install-dev-manager.sh"
    exit 1
  fi
}

create_first_window() {
  local window_name="$1"
  local working_dir="$2"
  local command="$3"

  if [[ ! -d "$working_dir" ]]; then
    echo "Erro: pasta não encontrada: $working_dir" >&2
    exit 1
  fi

  tmux new-session -d \
    -s "$SESSION" \
    -n "$window_name" \
    -c "$working_dir"

  tmux send-keys \
    -t "$SESSION:$window_name" \
    "$command" \
    C-m
}

add_window() {
  local window_name="$1"
  local working_dir="$2"
  local command="$3"

  if [[ ! -d "$working_dir" ]]; then
    echo "Aviso: pasta não encontrada; janela ignorada: $working_dir" >&2
    return 0
  fi

  tmux new-window \
    -t "$SESSION" \
    -n "$window_name" \
    -c "$working_dir"

  tmux send-keys \
    -t "$SESSION:$window_name" \
    "$command" \
    C-m
}

start_session() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "A sessão '$SESSION' já está rodando; conectando..."
    tmux attach-session -t "$SESSION"
    return
  fi

  echo "Criando sessão tmux '$SESSION'..."

  # A ordem destas chamadas define a ordem das janelas.
  # Para reordenar, mova apenas a linha completa correspondente.
  create_first_window "infra"      "$HOME/Code/sind-infra"          "bash ./deploy/auto-code-manager.sh"
  add_window          "sinproprev" "$HOME/Code/site-sinproprev-v2" "bash ./deploy/local.dev.sh"
  add_window          "asaclub"    "$HOME/Code/site-asaclub-2026"  "bash ./deploy/local.dev.sh"
  add_window          "site-inst"  "$HOME/Code/site-inst"          "bash ./deploy/local.dev.sh anpprev"
  add_window          "murm-app"   "$HOME/Code/murm-app"           "flutter run -d linux"

  tmux select-window -t "$SESSION:infra"
  tmux attach-session -t "$SESSION"
}

attach_session() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux attach-session -t "$SESSION"
  else
    echo "A sessão '$SESSION' não está rodando."
    echo "Use: dev-manager start"
    exit 1
  fi
}

stop_session() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux kill-session -t "$SESSION"
    echo "Sessão '$SESSION' encerrada."
  else
    echo "A sessão '$SESSION' já está parada."
  fi
}

status_session() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Sessão '$SESSION' rodando:"
    tmux list-windows -t "$SESSION"
  else
    echo "Sessão '$SESSION' parada."
  fi
}

require_tmux

case "${1:-start}" in
  start)
    start_session
    ;;
  attach)
    attach_session
    ;;
  stop)
    stop_session
    ;;
  restart)
    stop_session
    start_session
    ;;
  status)
    status_session
    ;;
  *)
    echo "Uso:"
    echo "  dev-manager start"
    echo "  dev-manager attach"
    echo "  dev-manager stop"
    echo "  dev-manager restart"
    echo "  dev-manager status"
    exit 1
    ;;
esac
