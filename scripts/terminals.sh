#!/usr/bin/env bash
# Abre um terminal diretamente em cada workspace do projeto, em uma única fase.
# Workspace 1 = LAZER; projetos ocupam 2..N e lrdp1/lrdp2 ficam no final.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=lib/project-config.sh
source "$PROJECT_ROOT/scripts/lib/project-config.sh"
# shellcheck source=project-names.sh
source "$PROJECT_ROOT/scripts/project-names.sh"
PLACEMENT_LIB="$PROJECT_ROOT/scripts/gnome-window-placement.sh"
PROJECTS_FILE="${PROJECTS_FILE:-$(dev_projects_file "$PROJECT_ROOT")}"
CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
STATE_ROOT="${AUTO_CODE_STATE_DIR:-$HOME/.local/state/dev-automation}"
STATE_DIR="$STATE_ROOT/desktops"
OPEN_INTERVAL_SECONDS="${TERMINALS_OPEN_INTERVAL_SECONDS:-2}"
TAB_INTERVAL_SECONDS="${TERMINALS_TAB_INTERVAL_SECONDS:-$OPEN_INTERVAL_SECONDS}"
CAPTURE_TIMEOUT_TENTHS="${TERMINALS_CAPTURE_TIMEOUT_TENTHS:-200}"

log(){ printf '[terminals] %s\n' "$*"; }
warn(){ printf '[terminals] AVISO: %s\n' "$*" >&2; }
fail(){ printf '[terminals] ERRO: %s\n' "$*" >&2; exit 1; }

[[ -f "$PLACEMENT_LIB" ]] || fail "biblioteca GNOME ausente: $PLACEMENT_LIB"
[[ -f "$PROJECTS_FILE" ]] || fail "arquivo de projetos não encontrado: $PROJECTS_FILE"
source "$PLACEMENT_LIB"

project_entries=()
project_dirs=()
load_projects() {
  local raw line path
  project_entries=()
  project_dirs=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    project_entries+=("$line")
    path="$CODE_ROOT/$line"
    if [[ -d "$path" ]]; then
      project_dirs+=("$(cd -- "$path" && pwd -P)")
    else
      project_dirs+=("$CODE_ROOT")
    fi
  done < <(dev_desktop_projects "$PROJECTS_FILE")

  project_entries+=("lrdp1" "lrdp2")
  project_dirs+=("$HOME" "$HOME")
}

terminal_backend() {
  local path
  if path="$(command -v ptyxis 2>/dev/null)"; then printf 'ptyxis\t%s\n' "$path"; return 0; fi
  if path="$(command -v gnome-terminal 2>/dev/null)"; then printf 'gnome-terminal\t%s\n' "$path"; return 0; fi
  if path="$(command -v kgx 2>/dev/null)"; then printf 'kgx\t%s\n' "$path"; return 0; fi
  if path="$(command -v xdg-terminal-exec 2>/dev/null)"; then printf 'xdg-terminal-exec\t%s\n' "$path"; return 0; fi
  if path="$(command -v x-terminal-emulator 2>/dev/null)"; then printf 'x-terminal-emulator\t%s\n' "$path"; return 0; fi
  return 1
}

project_display_name() {
  local project_path="$1" base word out=""
  base="$(basename -- "$project_path")"
  base="${base//_/ }"
  base="${base//-/ }"
  for word in $base; do
    case "${word,,}" in
      ai|api|aws|crm|erp|imap|lrdp|ses|ssh|ui|url) word="${word^^}" ;;
      *) word="${word^}" ;;
    esac
    out+="${out:+ }$word"
  done
  printf '%s\n' "$out"
}

terminal_exec_string() {
  local command_name="$1" command_line
  printf -v command_line 'export PATH="$HOME/.local/bin:$PATH"; exec %q' "$command_name"
  printf 'bash -lc %q\n' "$command_line"
}

launch_terminal_window() {
  local backend="$1" terminal="$2" working_dir="$3" title="${4:-}" command_name="${5:-}"
  local exec_string=""
  [[ -z "$command_name" ]] || exec_string="$(terminal_exec_string "$command_name")"

  case "$backend" in
    ptyxis)
      if [[ -n "$command_name" ]]; then
        nohup "$terminal" --new-window --working-directory="$working_dir" --title="$title" --execute "$exec_string" >/dev/null 2>&1 &
      else
        nohup "$terminal" --new-window --working-directory="$working_dir" ${title:+--title="$title"} >/dev/null 2>&1 &
      fi
      ;;
    gnome-terminal)
      if [[ -n "$command_name" ]]; then
        nohup "$terminal" --window --working-directory="$working_dir" --title="$title" -- bash -lc "export PATH=\"\$HOME/.local/bin:\$PATH\"; exec $command_name" >/dev/null 2>&1 &
      else
        nohup "$terminal" --window --working-directory="$working_dir" ${title:+--title="$title"} >/dev/null 2>&1 &
      fi
      ;;
    kgx)
      [[ -z "$command_name" ]] || return 2
      (cd -- "$working_dir" && nohup "$terminal" >/dev/null 2>&1 &)
      ;;
    xdg-terminal-exec)
      [[ -z "$command_name" ]] || return 2
      nohup "$terminal" --dir="$working_dir" >/dev/null 2>&1 &
      ;;
    x-terminal-emulator)
      [[ -z "$command_name" ]] || return 2
      (cd -- "$working_dir" && nohup "$terminal" >/dev/null 2>&1 &)
      ;;
    *) return 1 ;;
  esac
}

launch_terminal_tab() {
  local backend="$1" terminal="$2" working_dir="$3" title="$4" command_name="$5" exec_string
  exec_string="$(terminal_exec_string "$command_name")"
  case "$backend" in
    ptyxis)
      nohup "$terminal" --tab --working-directory="$working_dir" --title="$title" --execute "$exec_string" >/dev/null 2>&1 &
      ;;
    gnome-terminal)
      nohup "$terminal" --tab --working-directory="$working_dir" --title="$title" -- bash -lc "export PATH=\"\$HOME/.local/bin:\$PATH\"; exec $command_name" >/dev/null 2>&1 &
      ;;
    *) return 2 ;;
  esac
}

ensure_workspaces_on_all_monitors() {
  command -v gsettings >/dev/null 2>&1 || fail 'gsettings não encontrado; não consigo garantir um workspace por monitor.'
  gsettings set org.gnome.mutter workspaces-only-on-primary false || \
    fail 'não foi possível habilitar workspaces em todos os monitores.'
}

acquire_lock() {
  mkdir -p "$STATE_DIR"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$STATE_DIR/terminals.lock"
    flock -w 5 9 || fail 'já existe outra execução de terminals em andamento.'
    return 0
  fi

  local lock_dir="$STATE_DIR/terminals.lock.d"
  mkdir "$lock_dir" 2>/dev/null || fail 'já existe outra execução de terminals em andamento.'
  trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT
}

reset_previous_managed_batch() {
  [[ -s "$STATE_DIR/terminals.batch" ]] || return 0

  local fields managed overflow rc=0
  fields="$(printf 'count=%s' "$count")"
  log 'REALINHAMENTO: lote anterior detectado; fechando somente os terminais gerenciados pelo Dev Automation.'
  gnome_placement_prepare terminals managed-reset "$fields" || rc=$?
  case "$rc" in
    0) ;;
    75) fail "o controlador GNOME foi atualizado no disco, mas a sessão ainda usa o código antigo. Faça logout/login UMA vez e rode 'terminals' novamente." ;;
    76) fail "o controlador GNOME carregado não suporta o reset seguro do lote de terminals. Rode 'desktops --ensure-controller', faça logout/login UMA vez e execute 'terminals' novamente." ;;
    *) fail "não foi possível limpar o lote anterior de terminals${GNOME_PLACEMENT_LAST_ERROR:+: $GNOME_PLACEMENT_LAST_ERROR}." ;;
  esac
  managed="$(gnome_placement_ready_field managed 2>/dev/null || printf '0')"
  overflow="$(gnome_placement_ready_field overflow 2>/dev/null || printf '0')"
  log "REALINHAMENTO: fechamento solicitado para $((managed + overflow)) terminal(is) gerenciado(s); terminais manuais foram preservados."
}

# O reset mantém o protocolo estável para conseguir limpar o lote antigo mesmo
# antes de a sessão GNOME carregar o controlador novo.
legacy_compatible_reset() {
  gnome_placement_supported || fail 'terminals --reset requer GNOME/Wayland.'
  local info request ready result token tmp attempt line controller_rc=0

  "$PROJECT_ROOT/scripts/desktops.sh" --ensure-controller >/dev/null || controller_rc=$?
  if (( controller_rc != 0 && controller_rc != 75 )); then
    warn 'não foi possível preparar o controlador novo no disco; tentando ao menos limpar o lote atual.'
  fi
  info="$(gnome-extensions info workspace-name-osd@dev-automation 2>/dev/null || true)"
  grep -qiE '^[[:space:]]*State:[[:space:]]*ACTIVE[[:space:]]*$' <<<"$info" || \
    fail 'controlador GNOME não está ACTIVE; não vou fingir que fechei as janelas.'

  mkdir -p "$STATE_DIR"
  request="$STATE_DIR/terminals.request"
  ready="$STATE_DIR/terminals.ready"
  result="$STATE_DIR/terminals.result"
  token="$(date +%s%N)-$$-$RANDOM"
  tmp="$request.tmp.$$"
  rm -f -- "$ready" "$result"
  printf '%s	action=reset	count=%s
' "$token" "${#project_entries[@]}" > "$tmp"
  mv -f -- "$tmp" "$request"

  for ((attempt=0; attempt<100; attempt++)); do
    if [[ -s "$ready" ]]; then
      line="$(cat "$ready" 2>/dev/null || true)"
      if [[ "${line%%$'	'*}" == "$token" ]]; then
        log 'RESET confirmado: fechando o lote gerenciado e os terminais extras nos workspaces de projeto.'
        return 0
      fi
    fi
    sleep 0.1
  done
  fail 'o controlador GNOME não confirmou o reset.'
}

show_diagnose() {
  printf '=== TERMINALS / GNOME ===\n'
  printf 'Sessão: %s / %s\n' "${XDG_CURRENT_DESKTOP:-?}" "${XDG_SESSION_TYPE:-?}"
  printf 'Destinos: %s (projetos + lrdp1/lrdp2; workspaces 2..%s; LAZER excluído)\n' "$count" "$((count + 1))"
  printf 'Intervalo: %s segundo(s) entre abas/aberturas\n' "$TAB_INTERVAL_SECONDS"
  printf 'Terminal: '; terminal_backend || printf 'nenhum terminal compatível encontrado\n'
  printf 'Monitores:\n'
  command -v xrandr >/dev/null 2>&1 && xrandr --listmonitors 2>/dev/null || true
  printf 'Controlador: '
  if command -v gnome-extensions >/dev/null 2>&1; then
    gnome-extensions info workspace-name-osd@dev-automation 2>/dev/null | grep -E 'State:|Version:' | tr '\n' ' ' || true
    printf '\n'
  else
    printf 'gnome-extensions ausente\n'
  fi
  if [[ -s "$STATE_DIR/extension.ready" ]]; then
    printf 'Runtime:\n'
    sed 's/^/  /' "$STATE_DIR/extension.ready"
  fi
}

load_projects
count="${#project_entries[@]}"
(( count > 2 )) || fail 'nenhum projeto configurado para receber terminal.'

case "${1:-}" in
  --diagnose|diagnose) show_diagnose; exit 0 ;;
  --reset|reset)
    acquire_lock
    legacy_compatible_reset
    exit 0
    ;;
  --help|-h|help)
    printf 'Uso: terminals | terminals --reset | terminals --diagnose\n'
    printf 'Fluxo único: ativa cada workspace e abre uma janela por projeto. Projetos com deploy local/remoto recebem abas AUTO no mesmo terminal.\n'
    printf 'Aba local: <Projeto> Auto. Aba remota: Remote <Projeto> Auto. O intervalo padrão entre abas/aberturas é 2 segundos.\n'
    printf 'Subprojetos dentro de <projeto>/apps/... não recebem workspace próprio. LAZER (workspace 1) não recebe terminal automático; lrdp1/lrdp2 recebem os dois últimos terminais simples.\n'
    exit 0
    ;;
  '') ;;
  *) fail "opção inválida: $1" ;;
esac

[[ "$OPEN_INTERVAL_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || \
  fail "intervalo de abertura inválido: $OPEN_INTERVAL_SECONDS"
[[ "$TAB_INTERVAL_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || \
  fail "intervalo entre abas inválido: $TAB_INTERVAL_SECONDS"
[[ "$CAPTURE_TIMEOUT_TENTHS" =~ ^[0-9]+$ ]] || \
  fail "timeout inválido: $CAPTURE_TIMEOUT_TENTHS"

acquire_lock
IFS=$'\t' read -r terminal_kind terminal < <(terminal_backend) || \
  fail 'nenhum terminal compatível encontrado. Rode: terminals --diagnose'
ensure_workspaces_on_all_monitors
reset_previous_managed_batch

log 'FLUXO ÚNICO: uma janela por projeto/workspace; abas AUTO local e remota no mesmo terminal quando disponíveis.'
log "Terminal: $terminal_kind -> $terminal"
log "Intervalo entre abas/aberturas: $TAB_INTERVAL_SECONDS segundo(s)."

for ((project_index=0; project_index<count; project_index++)); do
  workspace_number=$((project_index + 2))
  slot=$((project_index + 1))
  project_name="${project_entries[$project_index]}"
  working_dir="${project_dirs[$project_index]}"
  request_fields="$(printf 'count=%s\tworkspace=%s\tslot=%s' "$count" "$workspace_number" "$slot")"

  log "ABRINDO $slot/$count: desktop $workspace_number · $project_name · $working_dir"
  placement_rc=0
  gnome_placement_prepare terminals direct "$request_fields" || placement_rc=$?
  case "$placement_rc" in
    0) ;;
    75)
      fail "o controlador GNOME foi atualizado no disco, mas a sessão ainda usa o código antigo. Faça logout/login UMA vez e rode 'terminals' novamente."
      ;;
    76)
      fail "o controlador GNOME carregado não suporta a associação direta desktop/slot. Rode 'desktops --ensure-controller', faça logout/login UMA vez e execute 'terminals' novamente."
      ;;
    *)
      fail "não foi possível ativar o desktop $workspace_number${GNOME_PLACEMENT_LAST_ERROR:+: $GNOME_PLACEMENT_LAST_ERROR}."
      ;;
  esac

  ready_action="$(gnome_placement_ready_field action 2>/dev/null || true)"
  ready_count="$(gnome_placement_ready_field count 2>/dev/null || true)"
  ready_workspace="$(gnome_placement_ready_field workspace 2>/dev/null || true)"
  ready_slot="$(gnome_placement_ready_field slot 2>/dev/null || true)"
  ready_monitor="$(gnome_placement_ready_field monitor 2>/dev/null || true)"
  ready_all_monitors="$(gnome_placement_ready_field all_monitors 2>/dev/null || true)"
  ready_valid="$(gnome_placement_ready_field valid 2>/dev/null || true)"
  [[ "$ready_action" == direct && "$ready_count" == "$count" && "$ready_valid" == 1 && \
     "$ready_workspace" == "$workspace_number" && "$ready_slot" == "$slot" && \
     "$ready_monitor" =~ ^[0-9]+$ && "$ready_all_monitors" == 1 ]] || \
    fail "o GNOME recusou o destino direto de '$project_name' (desktop esperado=$workspace_number, confirmado=${ready_workspace:-nenhum}; slot esperado=$slot, confirmado=${ready_slot:-nenhum}; monitor=${ready_monitor:-nenhum}; workspaces-em-todos-monitores=${ready_all_monitors:-não}; válido=${ready_valid:-não})."

  first_command=""
  second_command=""
  first_title=""
  second_title=""

  if [[ "$project_name" != lrdp1 && "$project_name" != lrdp2 && -d "$CODE_ROOT/$project_name" ]]; then
    command_base="$(project_global_command_base "$project_name" "$PROJECTS_FILE")"
    display_name="$(project_display_name "$project_name")"
    if [[ -f "$working_dir/deploy/local/setup.sh" ]]; then
      first_command="$command_base-auto"
      first_title="$display_name Auto"
    fi
    if [[ -f "$working_dir/deploy/remote/setup.sh" ]]; then
      if [[ -n "$first_command" ]]; then
        second_command="remote-$command_base-auto"
        second_title="Remote $display_name Auto"
      else
        first_command="remote-$command_base-auto"
        first_title="Remote $display_name Auto"
      fi
    fi
  fi

  launch_rc=0
  launch_terminal_window "$terminal_kind" "$terminal" "$working_dir" "$first_title" "$first_command" || launch_rc=$?
  case "$launch_rc" in
    0) ;;
    2) fail "o terminal $terminal_kind não suporta executar abas AUTO; instale/use Ptyxis ou GNOME Terminal." ;;
    *) fail "falha ao abrir terminal via $terminal_kind para '$project_name'" ;;
  esac

  if ! gnome_placement_wait_complete terminals "$CAPTURE_TIMEOUT_TENTHS"; then
    fail "o GNOME não confirmou o terminal de '$project_name' no desktop $workspace_number e no monitor da direita; parei para não abrir os seguintes no lugar errado."
  fi

  result_workspace="$(gnome_placement_result_field terminals workspace 2>/dev/null || true)"
  result_monitor="$(gnome_placement_result_field terminals monitor 2>/dev/null || true)"
  [[ "$result_workspace" == "$workspace_number" && "$result_monitor" == "$ready_monitor" ]] || \
    fail "o terminal de '$project_name' terminou no destino errado (desktop=${result_workspace:-nenhum}, monitor=${result_monitor:-nenhum}; esperado desktop=$workspace_number, monitor=$ready_monitor)."

  if [[ -n "$first_command" ]]; then
    log "ABA: $first_title -> $first_command"
  fi

  if [[ -n "$second_command" ]]; then
    sleep "$TAB_INTERVAL_SECONDS"
    launch_terminal_tab "$terminal_kind" "$terminal" "$working_dir" "$second_title" "$second_command" || \
      fail "falha ao abrir a aba '$second_title' via $terminal_kind"
    log "ABA: $second_title -> $second_command"
  fi

  if (( project_index + 1 < count )); then
    sleep "$TAB_INTERVAL_SECONDS"
  fi
done

log "CONCLUÍDO: $count janela(s) aberta(s) diretamente nos desktops 2..$((count + 1)); projetos com deploy receberam suas abas AUTO."
