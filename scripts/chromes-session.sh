#!/usr/bin/env bash
# Exclusão mútua compartilhada por chromes-all e pelo backend Ubuntu.
# O descritor é herdado pelo backend, mas nunca pelo processo do navegador.
chromes_session_lock() {
  if [[ "${CHROMES_LOCK_FD:-}" =~ ^[0-9]+$ && -e "/proc/$$/fd/$CHROMES_LOCK_FD" ]] &&
     [[ "${CHROMES_LOCK_OWNER:-}" == "$PPID" ]]; then
    return 0
  fi
  local dir="${AUTO_CODE_STATE_DIR:-$HOME/.local/state/dev-automation}/desktops"
  command -v flock >/dev/null 2>&1 || { printf '[chromes] ERRO: flock não encontrado.\n' >&2; return 1; }
  mkdir -p "$dir" || return 1
  exec {CHROMES_LOCK_FD}>"$dir/chromes.lock" || return 1
  if ! flock -n "$CHROMES_LOCK_FD"; then
    printf '[chromes] ERRO: outro chromes/chromes-all já está em execução; nenhuma janela foi aberta.\n' >&2
    return 1
  fi
  CHROMES_LOCK_OWNER="$$"
  export CHROMES_LOCK_FD CHROMES_LOCK_OWNER
}

chromes_session_unlock_child() {
  if [[ "${CHROMES_LOCK_FD:-}" =~ ^[0-9]+$ ]]; then
    exec {CHROMES_LOCK_FD}>&-
  fi
}
