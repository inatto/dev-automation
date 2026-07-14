#!/usr/bin/env bash

set -euo pipefail

SESSION="dev"

# Cria uma janela tmux e executa um comando nela.
#
# Uso:
#   add_window "nome-da-janela" "$HOME/Code/projeto" "comando"
#
# Para alterar a ordem, basta mover as linhas add_window dentro de start_session.
add_window() {
  local window_name="$1"
  local working_dir="$2"
  local command="$3"

  if [[ ! -d "$working_dir" ]]; then
    echo "Aviso: pasta não encontrada, janela ignorada: $working_dir" >&2
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

# Cria a primeira janela da sessão.
#
# A primeira janela precisa usar new-session em vez de new-window.
create_first_window() {
  local window_name="$1"
  local working_dir="$2"
  local command="$3"

  if [[ ! -d "$working_dir" ]]; then
    echo "Erro: pasta da primeira janela não encontrada: $working_dir" >&2
    exit 1
  fi

  tmux new-session \
    -d \
    -s "$SESSION" \
    -n "$window_name" \
    -c "$working_dir"

  tmux send-keys \
    -t "$SESSION:$window_name" \
    "$command" \
    C-m
}

start_session() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "A sessão '$SESSION' já está rodando."
    tmux attach-session -t "$SESSION"
    return
  fi

  echo "Criando sessão tmux '$SESSION'..."

  # A ordem das linhas abaixo define a ordem das janelas.
  # Para reordenar, basta mover uma linha inteira.

  create_first_window "infra"      "$HOME/Code/sind-infra"          "bash ./deploy/auto-code-manager.sh"
  add_window          "asaclub"    "$HOME/Code/site-asaclub-2026"  "bash ./deploy/local.dev.sh"
  add_window          "site-inst"  "$HOME/Code/site-inst"          "bash ./deploy/local.dev.sh anpprev"
  add_window          "sinproprev" "$HOME/Code/site-sinproprev-v2" "bash ./deploy/local.dev.sh"
  add_window          "murm-app"   "$HOME/Code/murm-app"           "flutter run -d linux"

  tmux select-window -t "$SESSION:infra"
  tmux attach-session -t "$SESSION"
}

attach_session() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux attach-session -t "$SESSION"
  else
    echo "A sessão '$SESSION' não está rodando."
    echo "Use: $0 start"
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
    echo "  $0 start"
    echo "  $0 attach"
    echo "  $0 stop"
    echo "  $0 restart"
    echo "  $0 status"
    exit 1
    ;;
esac
