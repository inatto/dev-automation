#!/usr/bin/env bash
# Backend Ubuntu/Linux do comando `files`.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
PLACEMENT_LIB="$PROJECT_ROOT/scripts/gnome-window-placement.sh"
[[ -f "$PLACEMENT_LIB" ]] && source "$PLACEMENT_LIB"

log(){ printf '[files] %s\n' "$*"; }
fail(){ printf '[files] ERRO: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  --help|-h|help)
    printf 'Uso: files\n'
    printf 'Abre /home/daniel/Code no workspace atual, monitor esquerdo e maximizado.\n'
    exit 0
    ;;
  "") ;;
  *) fail "opção inválida: $1" ;;
esac

files_dir="${FILES_DIR:-/home/daniel/Code}"
[[ -d "$files_dir" ]] || fail "diretório não encontrado: $files_dir"
command -v nautilus >/dev/null 2>&1 || fail 'Nautilus/Files não encontrado.'

placement_active=0
target_workspace=''
if [[ "${XDG_SESSION_TYPE:-}" == wayland ]] && command -v gnome-shell >/dev/null 2>&1; then
  declare -F gnome_placement_prepare >/dev/null 2>&1 || fail "biblioteca GNOME de posicionamento ausente: $PLACEMENT_LIB"
  placement_fields='maximize=1'
  if [[ -n "${FILES_TARGET_WORKSPACE:-}" ]]; then
    [[ "$FILES_TARGET_WORKSPACE" =~ ^[1-9][0-9]*$ ]] || fail 'FILES_TARGET_WORKSPACE deve ser inteiro positivo.'
    placement_fields="workspace=$FILES_TARGET_WORKSPACE"$'\t'"$placement_fields"
  fi
  gnome_placement_prepare chromes default "$placement_fields" || fail 'não foi possível preparar o monitor esquerdo no GNOME/Wayland.'
  placement_active=1
  target_workspace="$(gnome_placement_ready_field workspace 2>/dev/null || printf '?')"
  if [[ -n "${FILES_TARGET_WORKSPACE:-}" ]]; then
    log "Destino: workspace $target_workspace, monitor mais à esquerda, maximizado."
  else
    log "Destino: workspace atual $target_workspace, monitor mais à esquerda, maximizado."
  fi
fi

log "Abrindo Files em $files_dir..."
nohup nautilus --new-window "$files_dir" >/dev/null 2>&1 &

if (( placement_active )); then
  if gnome_placement_wait_min chromes nautilus 1 120; then
    if [[ -n "${FILES_TARGET_WORKSPACE:-}" ]]; then
      log "Files confirmado no workspace $target_workspace / monitor esquerdo."
    else
      log 'Files confirmado no workspace atual / monitor esquerdo.'
    fi
  else
    fail 'o GNOME não confirmou a nova janela Files no monitor esquerdo.'
  fi
fi
log 'Concluído.'
