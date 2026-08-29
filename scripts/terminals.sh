#!/usr/bin/env bash
# Abre um terminal diretamente em cada workspace do projeto, em uma única fase.
# Workspace 1 = LAZER; projetos ocupam 2..N e lrdp1/lrdp2 ficam no final.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=lib/project-config.sh
source "$PROJECT_ROOT/scripts/lib/project-config.sh"
PLACEMENT_LIB="$PROJECT_ROOT/scripts/gnome-window-placement.sh"
PROJECTS_FILE="${PROJECTS_FILE:-$(dev_projects_file "$PROJECT_ROOT")}"
CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
STATE_ROOT="${AUTO_CODE_STATE_DIR:-$HOME/.local/state/dev-automation}"
STATE_DIR="$STATE_ROOT/desktops"
OPEN_INTERVAL_SECONDS="${TERMINALS_OPEN_INTERVAL_SECONDS:-1.5}"
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
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#./}"
    line="${line%/}"
    [[ -n "$line" && "${line,,}" != *.zip ]] || continue

    project_entries+=("$line")
    path="$CODE_ROOT/$line"
    if [[ -d "$path" ]]; then
      project_dirs+=("$(cd -- "$path" && pwd -P)")
    else
      project_dirs+=("$CODE_ROOT")
    fi
  done < "$PROJECTS_FILE"

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

launch_terminal_window() {
  local backend="$1" terminal="$2" working_dir="$3"
  case "$backend" in
    ptyxis) nohup "$terminal" --new-window --working-directory="$working_dir" >/dev/null 2>&1 & ;;
    gnome-terminal) nohup "$terminal" --window --working-directory="$working_dir" >/dev/null 2>&1 & ;;
    kgx) (cd -- "$working_dir" && nohup "$terminal" >/dev/null 2>&1 &) ;;
    xdg-terminal-exec) nohup "$terminal" --dir="$working_dir" >/dev/null 2>&1 & ;;
    x-terminal-emulator) (cd -- "$working_dir" && nohup "$terminal" >/dev/null 2>&1 &) ;;
    *) return 1 ;;
  esac
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
  printf 'Intervalo: %s segundo(s) entre aberturas\n' "$OPEN_INTERVAL_SECONDS"
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
    printf 'Fluxo único: ativa cada workspace, abre o terminal na pasta correspondente e aguarda 1,5 segundo antes do próximo.\n'
    printf 'LAZER (workspace 1) não recebe terminal automático; lrdp1/lrdp2 recebem os dois últimos.\n'
    exit 0
    ;;
  '') ;;
  *) fail "opção inválida: $1" ;;
esac

[[ "$OPEN_INTERVAL_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || \
  fail "intervalo inválido: $OPEN_INTERVAL_SECONDS"
[[ "$CAPTURE_TIMEOUT_TENTHS" =~ ^[0-9]+$ ]] || \
  fail "timeout inválido: $CAPTURE_TIMEOUT_TENTHS"

acquire_lock
IFS=$'\t' read -r terminal_kind terminal < <(terminal_backend) || \
  fail 'nenhum terminal compatível encontrado. Rode: terminals --diagnose'

log 'FLUXO ÚNICO: cada terminal será aberto diretamente no seu workspace e na pasta do projeto.'
log "Terminal: $terminal_kind -> $terminal"
log "Intervalo entre aberturas: $OPEN_INTERVAL_SECONDS segundo(s)."

for ((project_index=0; project_index<count; project_index++)); do
  workspace_number=$((project_index + 2))
  slot=$((project_index + 1))
  project_name="${project_entries[$project_index]}"
  working_dir="${project_dirs[$project_index]}"
  request_fields="$(printf 'count=%s\tworkspace=%s\tslot=%s' "$count" "$workspace_number" "$slot")"

  log "ABRINDO $slot/$count: desktop $workspace_number · $project_name · $working_dir"
  if ! gnome_placement_prepare terminals direct "$request_fields"; then
    fail "não foi possível ativar o desktop $workspace_number. Rode 'desktops' e faça logout/login uma vez se o controlador tiver sido atualizado."
  fi

  ready_workspace="$(gnome_placement_ready_field workspace 2>/dev/null || true)"
  ready_slot="$(gnome_placement_ready_field slot 2>/dev/null || true)"
  ready_valid="$(gnome_placement_ready_field valid 2>/dev/null || true)"
  [[ "$ready_valid" == 1 && "$ready_workspace" == "$workspace_number" && "$ready_slot" == "$slot" ]] || \
    fail "o GNOME não confirmou o destino de '$project_name' (desktop=${ready_workspace:-?}, slot=${ready_slot:-?})."

  launch_terminal_window "$terminal_kind" "$terminal" "$working_dir" || \
    fail "falha ao abrir terminal via $terminal_kind para '$project_name'"

  if ! gnome_placement_wait_complete terminals "$CAPTURE_TIMEOUT_TENTHS"; then
    fail "o GNOME não confirmou o terminal de '$project_name' no desktop $workspace_number; parei para não abrir os seguintes no lugar errado."
  fi

  if (( project_index + 1 < count )); then
    sleep "$OPEN_INTERVAL_SECONDS"
  fi
done

log "CONCLUÍDO: $count terminal(is) aberto(s) diretamente nos desktops 2..$((count + 1)), sem segunda fase."
