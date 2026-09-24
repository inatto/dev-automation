#!/usr/bin/env bash
# Fecha todos os emuladores de terminal pertencentes à sessão gráfica atual.
# O encerramento é agendado alguns milissegundos depois para que o comando
# consiga retornar antes de fechar o terminal a partir do qual foi executado.
set -euo pipefail

log(){ printf '[terminals-close] %s\n' "$*"; }
fail(){ printf '[terminals-close] ERRO: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  --help|-h|help)
    printf 'Uso: terminals-close\n'
    printf 'Fecha todos os emuladores de terminal da sessão gráfica atual.\n'
    exit 0
    ;;
  '') ;;
  *) fail "opção inválida: $1" ;;
esac

current_wayland="${WAYLAND_DISPLAY:-}"
current_display="${DISPLAY:-}"
current_session="${XDG_SESSION_ID:-}"

# Somente processos de emuladores gráficos; shells/SSH/tmux não são alvos.
terminal_executables=(
  ptyxis
  gnome-terminal-server
  gnome-terminal
  kgx
  gnome-console
  xterm
  konsole
  xfce4-terminal
  mate-terminal
  tilix
  terminator
  alacritty
  kitty
  wezterm-gui
  foot
)

is_terminal_executable() {
  local name="$1" candidate
  for candidate in "${terminal_executables[@]}"; do
    [[ "$name" == "$candidate" ]] && return 0
  done
  return 1
}

belongs_to_current_graphical_session() {
  local pid="$1" env_file="/proc/$pid/environ" env_text
  [[ -r "$env_file" ]] || return 1
  env_text="$(tr '\0' '\n' < "$env_file" 2>/dev/null || true)"

  if [[ -n "$current_wayland" ]] && grep -Fxq "WAYLAND_DISPLAY=$current_wayland" <<<"$env_text"; then
    return 0
  fi
  if [[ -n "$current_display" ]] && grep -Fxq "DISPLAY=$current_display" <<<"$env_text"; then
    return 0
  fi
  if [[ -n "$current_session" ]] && grep -Fxq "XDG_SESSION_ID=$current_session" <<<"$env_text"; then
    return 0
  fi

  # Em uma sessão sem identificadores gráficos exportados, limita ao próprio
  # usuário em vez de fingir que conseguiu distinguir sessões inexistentes.
  [[ -z "$current_wayland" && -z "$current_display" && -z "$current_session" ]]
}

pids=()
for proc_dir in /proc/[0-9]*; do
  pid="${proc_dir##*/}"
  [[ "$pid" != "$$" ]] || continue
  [[ -r "$proc_dir/status" ]] || continue

  proc_uid="$(awk '/^Uid:/{print $2; exit}' "$proc_dir/status" 2>/dev/null || true)"
  [[ "$proc_uid" == "$UID" ]] || continue

  exe="$(readlink -f "$proc_dir/exe" 2>/dev/null || true)"
  [[ -n "$exe" ]] || continue
  exe_name="${exe##*/}"
  is_terminal_executable "$exe_name" || continue
  belongs_to_current_graphical_session "$pid" || continue
  pids+=("$pid")
done

if ((${#pids[@]} == 0)); then
  log 'nenhum terminal gráfico aberto nesta sessão.'
  exit 0
fi

# O helper fica independente do terminal atual e envia SIGTERM somente depois
# que este comando já imprimiu o resultado e devolveu o controle ao shell.
(
  sleep 0.20
  for pid in "${pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
) </dev/null >/dev/null 2>&1 &

disown 2>/dev/null || true
log "fechando ${#pids[@]} processo(s) de terminal da sessão atual."
