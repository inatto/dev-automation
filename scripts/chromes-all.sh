#!/usr/bin/env bash
# Executa `chromes` uma vez em cada workspace de projeto.
# Workspace 1 = LAZER; projetos começam no workspace 2.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
CONTEXT_LIB="$PROJECT_ROOT/scripts/workspace-project-context.sh"
CHROMES_COMMAND="${CHROMES_COMMAND:-$PROJECT_ROOT/scripts/chromes.sh}"
DESKTOPS_COMMAND="${DESKTOPS_COMMAND:-$PROJECT_ROOT/scripts/desktops.sh}"
DESKTOP_DELAY_SECONDS=2

[[ -f "$CONTEXT_LIB" ]] || { printf '[chromes-all] ERRO: contexto ausente: %s\n' "$CONTEXT_LIB" >&2; exit 1; }
source "$CONTEXT_LIB"

log(){ printf '[chromes-all] %s\n' "$*"; }
fail(){ printf '[chromes-all] ERRO: %s\n' "$*" >&2; exit 1; }

[[ -x "$CHROMES_COMMAND" ]] || fail "comando chromes não encontrado/executável: $CHROMES_COMMAND"
[[ -x "$DESKTOPS_COMMAND" ]] || fail "comando desktops não encontrado/executável: $DESKTOPS_COMMAND"

case "${1:-}" in
  --help|-h|help)
    cat <<HELP
Uso: chromes-all

Executa `chromes` em cada workspace de projeto.
O próprio `chromes` resolve o projeto/URL do workspace e abre:
  - Chrome 1: Daniel/danielmaiax -> https://chatgpt.com/
  - Chrome 2: Sindicatto -> URL(s) local(is), somente quando existirem
  - monitor esquerdo, maximizado
Intervalo entre desktops: 2s.
HELP
    exit 0
    ;;
  "") ;;
  *) fail "opção inválida: $1" ;;
esac

workspace_context_load_projects || fail "arquivo de projetos não encontrado: $PROJECTS_FILE"
[[ -f "$SERVICES_FILE" ]] || fail "arquivo de serviços não encontrado: $SERVICES_FILE"
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
  log "workspace $workspace [$name]: chromes"
  PROJECTS_FILE="$PROJECTS_FILE" \
  SERVICES_FILE="$SERVICES_FILE" \
  CHROMES_TARGET_WORKSPACE="$workspace" \
    "$CHROMES_COMMAND"
  if (( i + 1 < ${#WORKSPACE_PROJECTS[@]} )); then
    sleep "$DESKTOP_DELAY_SECONDS"
  fi
done

log 'Concluído.'
