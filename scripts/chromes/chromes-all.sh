#!/usr/bin/env bash
# Executa `chromes` no LAZER e uma vez em cada workspace de projeto.
# Workspace 1 = LAZER (Chrome Daniel); projetos começam no workspace 2.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
CONTEXT_LIB="$PROJECT_ROOT/scripts/core/workspace-project-context.sh"
CHROMES_COMMAND="${CHROMES_COMMAND:-$PROJECT_ROOT/scripts/chromes/chromes.sh}"
DESKTOPS_COMMAND="${DESKTOPS_COMMAND:-$PROJECT_ROOT/scripts/desktops/desktops.sh}"
DESKTOP_DELAY_SECONDS=1

[[ -f "$CONTEXT_LIB" ]] || { printf '[chromes-all] ERRO: contexto ausente: %s\n' "$CONTEXT_LIB" >&2; exit 1; }
source "$CONTEXT_LIB"
source "$PROJECT_ROOT/scripts/core/gnome-window-placement.sh"
source "$PROJECT_ROOT/scripts/chromes/chromes-session.sh"

log(){ printf '[chromes-all] %s\n' "$*"; }
fail(){ printf '[chromes-all] ERRO: %s\n' "$*" >&2; exit 1; }

[[ -x "$CHROMES_COMMAND" ]] || fail "comando chromes não encontrado/executável: $CHROMES_COMMAND"
[[ -x "$DESKTOPS_COMMAND" ]] || fail "comando desktops não encontrado/executável: $DESKTOPS_COMMAND"

register_existing=0
case "${1:-}" in
  --help|-h|help)
    cat <<'HELP'
Uso: chromes-all | chromes-all --register-existing

No GNOME/Wayland, janelas já registradas são apenas reposicionadas por projeto.
Não fecha/reinicia navegadores nem abre janelas quando há um lote parcial/ambíguo.
Sem janelas gerenciadas abertas, executa `chromes` no LAZER e em cada workspace de projeto.
O próprio `chromes` resolve o projeto/URL do workspace e abre:
  - Workspace 1 / LAZER: Chrome Daniel/danielmaiax -> https://chatgpt.com/
  - Projetos: Chrome Daniel/danielmaiax -> Project ChatGPT mapeado (fallback https://chatgpt.com/)
  - Chrome 2: Sindicatto -> URL(s) local(is), somente quando existirem
  - Chrome 3: Clientes Sindicatto -> as mesmas URL(s) locais do Sindicatto
  - monitor esquerdo, maximizado
Intervalo entre desktops na abertura: 1s.
--register-existing: registra janelas antigas já organizadas nos workspaces corretos,
sem abrir, fechar ou mover. Use somente após conferir a disposição de cada projeto.
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
  # LAZER também faz parte do lote gerenciado. A chave reservada @lazer
  # não representa projeto em disco; identifica somente a janela Daniel do workspace 1.
  printf '%s\t%s\t%s\n' '@lazer' '1' '1' >> "$plan_tmp"
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
  gnome_placement_prepare chromes "$action" "plan=$plan" || fail 'o controlador GNOME não confirmou a identificação; nenhuma janela foi aberta.'
  valid="$(gnome_placement_ready_field valid 2>/dev/null || true)"
  [[ "$valid" == 1 ]] || fail 'não foi possível identificar um lote seguro. Para registrar janelas antigas, organize-as por projeto e use chromes-all --register-existing.'
  if (( register_existing )); then
    log 'Janelas existentes registradas por projeto; nenhuma janela foi aberta, fechada ou movida.'
    exit 0
  fi
  managed="$(gnome_placement_ready_field managed)"
  missing="$(gnome_placement_ready_field missing)"
  untracked="$(gnome_placement_ready_field untracked)"
  overflow="$(gnome_placement_ready_field overflow)"
  if (( managed > 0 )); then
    log "Reposicionando $managed janela(s) existente(s), conforme a ordem dos projetos..."
    gnome_placement_prepare chromes reconcile "plan=$plan" || fail 'não foi possível iniciar o reposicionamento; todas as janelas foram preservadas.'
    [[ "$(gnome_placement_ready_field valid 2>/dev/null || true)" == 1 ]] || fail 'o lote mudou durante a identificação; nenhuma janela foi aberta ou fechada.'
    gnome_placement_wait_complete chromes 120 || fail 'o GNOME não confirmou todas as posições; nenhuma janela foi aberta ou fechada.'
    # Releia os contadores: janelas podem ter sido fechadas manualmente entre pedidos.
    missing="$(gnome_placement_ready_field missing)"
    untracked="$(gnome_placement_ready_field untracked)"
    overflow="$(gnome_placement_ready_field overflow)"
    log 'Janelas identificadas reposicionadas no monitor esquerdo e maximizadas; nenhuma janela foi aberta ou fechada.'
    if (( missing > 0 || untracked > 0 || overflow > 0 )); then
      fail "lote parcial/ambíguo: $missing faltando, $untracked sem vínculo, $overflow extra(s). Preservei tudo e não criei duplicatas."
    fi
    exit 0
  fi
  if (( untracked > 0 || overflow > 0 )); then
    fail 'há janelas de projeto sem vínculo seguro; preservei tudo e não abri duplicatas. Organize as janelas antigas e use chromes-all --register-existing uma vez.'
  fi
fi

log "Workspaces Chrome: $(( ${#WORKSPACE_PROJECTS[@]} + 1 )) (LAZER + ${#WORKSPACE_PROJECTS[@]} projetos); intervalo: 1s; monitor: esquerdo; maximizado: sim."

log 'workspace 1 [LAZER]: Chrome Daniel'
PROJECTS_FILE="$PROJECTS_FILE" \
SERVICES_FILE="$SERVICES_FILE" \
CHROMES_TARGET_WORKSPACE=1 \
CHROMES_MANAGED_PROJECT='@lazer' \
CHROMES_MANAGED_EXPECTED=1 \
CHROMES_SKIP_SECOND=1 \
CHROMES_LOCAL_URLS='' \
  "$CHROMES_COMMAND"

if ((${#WORKSPACE_PROJECTS[@]} > 0)); then
  sleep "$DESKTOP_DELAY_SECONDS"
fi

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
