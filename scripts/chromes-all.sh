#!/usr/bin/env bash
# Executa `chromes` uma vez em cada workspace de projeto.
# Workspace 1 = LAZER; projetos começam no workspace 2.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
CONTEXT_LIB="$PROJECT_ROOT/scripts/workspace-project-context.sh"
CHROMES_COMMAND="${CHROMES_COMMAND:-$PROJECT_ROOT/scripts/chromes.sh}"
DESKTOPS_COMMAND="${DESKTOPS_COMMAND:-$PROJECT_ROOT/scripts/desktops.sh}"
DESKTOP_DELAY_SECONDS=1

[[ -f "$CONTEXT_LIB" ]] || { printf '[chromes-all] ERRO: contexto ausente: %s\n' "$CONTEXT_LIB" >&2; exit 1; }
source "$CONTEXT_LIB"
source "$PROJECT_ROOT/scripts/gnome-window-placement.sh"
source "$PROJECT_ROOT/scripts/chromes-session.sh"

log(){ printf '[chromes-all] %s\n' "$*"; }
fail(){ printf '[chromes-all] ERRO: %s\n' "$*" >&2; exit 1; }

[[ -x "$CHROMES_COMMAND" ]] || fail "comando chromes não encontrado/executável: $CHROMES_COMMAND"
[[ -x "$DESKTOPS_COMMAND" ]] || fail "comando desktops não encontrado/executável: $DESKTOPS_COMMAND"

register_existing=0
case "${1:-}" in
  --help|-h|help)
    cat <<'HELP'
Uso: chromes-all

No GNOME/Wayland, um conjunto completo identificado é apenas reposicionado por projeto.
Se o conjunto estiver ausente, parcial ou ambíguo, abre um novo conjunto conforme a configuração atual.
Não exige registro manual de janelas existentes.
O próprio `chromes` resolve o projeto/URL do workspace e abre:
  - Chrome 1: Daniel/danielmaiax -> Project ChatGPT correspondente em config/chatgpt-projects.urls
    (fallback: https://chatgpt.com/ quando não houver mapeamento)
  - Chrome 2: Sindicatto -> URL(s) local(is), somente quando existirem
  - Chrome 3: Sindicatto Clientes (Profile 12) -> mesmas URL(s) locais do Chrome 2
  - monitor esquerdo, maximizado
Intervalo entre desktops na abertura: 1s.
A associação sobrevive à suspensão/reabilitação da extensão na mesma sessão GNOME.
HELP
    exit 0
    ;;
  --register-existing) register_existing=1 ;;
  "") ;;
  *) fail "opção inválida: $1" ;;
esac

workspace_context_load_projects || fail "arquivo de projetos não encontrado: $PROJECTS_FILE"
[[ -f "$SERVICES_FILE" ]] || fail "arquivo de serviços não encontrado: $SERVICES_FILE"
((${#WORKSPACE_PROJECTS[@]} > 0)) || fail 'nenhum projeto ativo configurado.'

managed_mode=0
if [[ "${XDG_SESSION_TYPE:-}" == wayland ]] && command -v gnome-shell >/dev/null 2>&1; then
  chromes_session_lock || exit 1
  log 'Sincronizando workspaces antes de conferir as janelas...'
  PROJECTS_FILE="$PROJECTS_FILE" DESKTOPS_PLATFORM=gnome "$DESKTOPS_COMMAND" >/dev/null || \
    fail 'não foi possível sincronizar os workspaces GNOME.'
  managed_mode=1
elif (( register_existing )); then
  fail '--register-existing requer GNOME/Wayland.'
fi

# A chave é o caminho completo do projeto; a posição atual de uma janela nunca
# define sua identidade. O plano segue exatamente a lista usada pelos desktops.
expected_counts=()
if (( managed_mode )); then
  workspace_context_load_services || fail 'não foi possível ler os serviços.'
  mkdir -p "$GNOME_PLACEMENT_STATE_DIR"
  plan="$GNOME_PLACEMENT_STATE_DIR/chromes.plan"
  plan_tmp="$(mktemp "$plan.XXXXXX")"
  trap 'rm -f -- "$plan_tmp"' EXIT
  for ((i=0; i<${#WORKSPACE_PROJECTS[@]}; i++)); do
    entry="${WORKSPACE_PROJECTS[$i]}"
    [[ "$entry" != *$'\t'* && "$entry" != *$'\n'* && "$entry" != *$'\r'* ]] || fail 'projeto com separadores inválidos.'
    urls="${CHROMES_LOCAL_URLS:-$(workspace_context_urls_for_project "$entry" 2>/dev/null || true)}"
    expected=1
    if [[ "${CHROMES_SKIP_SECOND:-}" != 1 ]] && grep -q '[^[:space:]]' <<<"$urls"; then
      expected=3
    fi
    expected_counts+=("$expected")
    printf '%s\t%s\t%s\n' "$entry" "$((i + 2))" "$expected" >> "$plan_tmp"
  done
  mv -f -- "$plan_tmp" "$plan"
  action=status
  (( register_existing )) && action=register
  status_ok=1
  if ! gnome_placement_prepare chromes "$action" "plan=$plan"; then
    status_ok=0
  fi
  valid=0
  if (( status_ok )); then
    valid="$(gnome_placement_ready_field valid 2>/dev/null || true)"
  fi

  if (( register_existing )) && [[ "$valid" == 1 ]]; then
    log 'Janelas existentes registradas por projeto; nenhuma janela foi aberta, fechada ou movida.'
    exit 0
  fi

  if [[ "$valid" == 1 ]]; then
    managed="$(gnome_placement_ready_field managed 2>/dev/null || echo 0)"
    missing="$(gnome_placement_ready_field missing 2>/dev/null || echo 0)"
    untracked="$(gnome_placement_ready_field untracked 2>/dev/null || echo 0)"
    overflow="$(gnome_placement_ready_field overflow 2>/dev/null || echo 0)"
  else
    managed=0
    missing=0
    untracked=0
    overflow=0
    log 'Não foi possível identificar com segurança as janelas existentes; vou abrir um novo conjunto conforme a configuração atual.'
  fi

  if (( managed > 0 )); then
    log "Reposicionando $managed janela(s) existente(s), conforme a ordem dos projetos..."
    reconcile_ok=1
    if ! gnome_placement_prepare chromes reconcile "plan=$plan"; then
      reconcile_ok=0
    elif [[ "$(gnome_placement_ready_field valid 2>/dev/null || true)" != 1 ]]; then
      reconcile_ok=0
    fi

    if (( reconcile_ok )) && gnome_placement_wait_complete chromes 30; then
      missing="$(gnome_placement_ready_field missing 2>/dev/null || echo 0)"
      untracked="$(gnome_placement_ready_field untracked 2>/dev/null || echo 0)"
      overflow="$(gnome_placement_ready_field overflow 2>/dev/null || echo 0)"
      log 'Janelas identificadas reposicionadas no monitor esquerdo e maximizadas.'
      if (( missing == 0 && untracked == 0 && overflow == 0 )); then
        exit 0
      fi
      log "Conjunto parcial/ambíguo ($missing faltando, $untracked sem vínculo, $overflow extra(s)); vou abrir um novo conjunto completo sem exigir registro manual."
    else
      log 'O GNOME não confirmou o reposicionamento; vou abrir um novo conjunto em vez de abortar.'
    fi
  elif (( untracked > 0 || overflow > 0 )); then
    log "Há janelas sem vínculo seguro ($untracked sem vínculo, $overflow extra(s)); vou abrir um novo conjunto completo sem exigir registro manual."
  fi

fi

log "Projetos: ${#WORKSPACE_PROJECTS[@]}; intervalo: 1s; monitor: esquerdo; maximizado: sim."
for ((i=0; i<${#WORKSPACE_PROJECTS[@]}; i++)); do
  entry="${WORKSPACE_PROJECTS[$i]}"
  name="$(basename -- "$entry")"
  workspace=$((i + 2))
  log "workspace $workspace [$name]: chromes"
  PROJECTS_FILE="$PROJECTS_FILE" \
  SERVICES_FILE="$SERVICES_FILE" \
  CHROMES_TARGET_WORKSPACE="$workspace" \
  CHROMES_MANAGED_PROJECT="${entry}" \
  CHROMES_MANAGED_EXPECTED="${expected_counts[$i]:-0}" \
    "$CHROMES_COMMAND"
  if (( i + 1 < ${#WORKSPACE_PROJECTS[@]} )); then
    sleep "$DESKTOP_DELAY_SECONDS"
  fi
done

log 'Concluído.'
