#!/usr/bin/env bash

set -euo pipefail

SESSION="dev"
WINDOW="projetos"

require_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "Erro: tmux não está instalado."
    echo "Execute uma vez:"
    echo "  /home/daniel/Code/sind-infra/deploy/install-dev-manager.sh"
    exit 1
  fi
}

validate_dir() {
  local working_dir="$1"
  local required="${2:-false}"

  if [[ -d "$working_dir" ]]; then
    return 0
  fi

  if [[ "$required" == "true" ]]; then
    echo "Erro: pasta não encontrada: $working_dir" >&2
    exit 1
  fi

  echo "Aviso: pasta não encontrada; painel ignorado: $working_dir" >&2
  return 1
}

configure_window() {
  tmux set-option -t "$SESSION" pane-border-status top
  tmux set-option -t "$SESSION" pane-border-format ' #[bold]#{pane_title} #[default]'
  tmux set-option -t "$SESSION" remain-on-exit on
}

create_first_pane() {
  local pane_name="$1"
  local working_dir="$2"
  local command="$3"

  validate_dir "$working_dir" true

  tmux new-session -d \
    -s "$SESSION" \
    -n "$WINDOW" \
    -c "$working_dir"

  tmux select-pane -t "$SESSION:$WINDOW.0" -T "$pane_name"
  tmux send-keys -t "$SESSION:$WINDOW.0" "$command" C-m
}

add_pane() {
  local pane_name="$1"
  local working_dir="$2"
  local command="$3"
  local pane_id

  validate_dir "$working_dir" || return 0

  pane_id="$(
    tmux split-window \
      -h \
      -P \
      -F '#{pane_id}' \
      -t "$SESSION:$WINDOW" \
      -c "$working_dir"
  )"

  tmux select-pane -t "$pane_id" -T "$pane_name"
  tmux send-keys -t "$pane_id" "$command" C-m

  # Redistribui todos os painéis igualmente após cada inclusão.
  tmux select-layout -t "$SESSION:$WINDOW" even-horizontal
}

start_session() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "A sessão '$SESSION' já está rodando; conectando..."
    tmux attach-session -t "$SESSION"
    return
  fi

  echo "Criando sessão tmux '$SESSION' com os projetos lado a lado..."

  # A ordem destas chamadas define a ordem dos painéis, da esquerda para a direita.
  create_first_pane "infra"      "$HOME/Code/sind-infra"          "bash ./deploy/auto-code-manager.sh"
  configure_window
  add_pane          "asaclub"                     "$HOME/Code/site-asaclub-2026"            "bash ./deploy/local.dev.sh"
  add_pane          "site-inst"                   "$HOME/Code/site-inst"                    "bash ./deploy/local.dev.sh anpprev"
  add_pane          "sinproprev"                  "$HOME/Code/site-sinproprev-v2"           "bash ./deploy/local.dev.sh"
  add_pane          "site-asaclub-admin-mariadb"  "$HOME/Code/site-asaclub-admin-mariadb"   "bash ./deploy/local.dev.sh"

#  add_pane          "murm-app"   "$HOME/Code/murm-app"           "flutter run -d linux"

  tmux select-layout -t "$SESSION:$WINDOW" even-horizontal
  tmux select-pane -t "$SESSION:$WINDOW.0"
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
    tmux list-panes \
      -t "$SESSION:$WINDOW" \
      -F '  painel #{pane_index}: #{pane_title} | #{pane_current_path} | #{pane_current_command}'
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