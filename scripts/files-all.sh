#!/usr/bin/env bash
# Executa `files` uma vez em cada workspace de projeto.
# Workspace 1 = LAZER; projetos começam no workspace 2.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
CONTEXT_LIB="$PROJECT_ROOT/scripts/workspace-project-context.sh"
FILES_COMMAND="${FILES_COMMAND:-$PROJECT_ROOT/scripts/files.sh}"
DESKTOPS_COMMAND="${DESKTOPS_COMMAND:-$PROJECT_ROOT/scripts/desktops.sh}"
DESKTOP_DELAY_SECONDS=1

[[ -f "$CONTEXT_LIB" ]] || { printf '[files-all] ERRO: contexto ausente: %s\n' "$CONTEXT_LIB" >&2; exit 1; }
source "$CONTEXT_LIB"

log(){ printf '[files-all] %s\n' "$*"; }
fail(){ printf '[files-all] ERRO: %s\n' "$*" >&2; exit 1; }

[[ -x "$FILES_COMMAND" ]] || fail "comando files não encontrado/executável: $FILES_COMMAND"
[[ -x "$DESKTOPS_COMMAND" ]] || fail "comando desktops não encontrado/executável: $DESKTOPS_COMMAND"

case "${1:-}" in
  --help|-h|help)
    cat <<HELP
Uso: files-all

Executa `files` em cada workspace de projeto.
Destino: /home/daniel/Code, monitor esquerdo, maximizado.
Intervalo entre desktops: 2s.
HELP
    exit 0
    ;;
  "") ;;
  *) fail "opção inválida: $1" ;;
esac

workspace_context_load_projects || fail "arquivo de projetos não encontrado: $PROJECTS_FILE"
((${#WORKSPACE_PROJECTS[@]} > 0)) || fail 'nenhum projeto ativo configurado.'

if [[ "${XDG_SESSION_TYPE:-}" == wayland ]] && command -v gnome-shell >/dev/null 2>&1; then
  log 'Sincronizando workspaces antes da abertura...'
  PROJECTS_FILE="$PROJECTS_FILE" DESKTOPS_PLATFORM=gnome "$DESKTOPS_COMMAND" >/dev/null || \
    fail 'não foi possível sincronizar os workspaces GNOME.'
fi

log "Projetos: ${#WORKSPACE_PROJECTS[@]}; intervalo: 2s; monitor: esquerdo; maximizado: sim."
for ((i=0; i<${#WORKSPACE_PROJECTS[@]}; i++)); do
  entry="${WORKSPACE_PROJECTS[$i]}"
  name="$(basename -- "$entry")"
  workspace=$((i + 2))
  log "workspace $workspace [$name]: files"
  FILES_TARGET_WORKSPACE="$workspace" "$FILES_COMMAND"
  if (( i + 1 < ${#WORKSPACE_PROJECTS[@]} )); then
    sleep "$DESKTOP_DELAY_SECONDS"
  fi
done

log 'Concluído.'
