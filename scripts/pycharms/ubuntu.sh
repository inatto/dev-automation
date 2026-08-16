#!/usr/bin/env bash
# Backend Ubuntu/Linux do comando `pycharms`.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
CONFIG_FILE="${PYCHARMS_PROJECTS_FILE:-$PROJECT_ROOT/config/auto-code-manager.projects}"
CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
OPEN_DELAY_SECONDS="${PYCHARMS_OPEN_DELAY_SECONDS:-1}"
STARTUP_SETTLE_SECONDS="${PYCHARMS_STARTUP_SETTLE_SECONDS:-15}"
GNOME_WAYLAND_HELPER="$SCRIPT_DIR/gnome-wayland.sh"
DESKTOPS_SCRIPT="$PROJECT_ROOT/scripts/desktops.sh"
STATE_DIR="${AUTO_CODE_STATE_DIR:-$HOME/.local/state/dev-automation}/pycharms"
WORKSPACE_MAP="$STATE_DIR/workspaces.tsv"
BATCH_MARKER="$STATE_DIR/batch-opening"
RECONCILE_REQUEST="$STATE_DIR/reconcile.request"
log(){ printf '[pycharms] %s\n' "$*"; }
warn(){ printf '[pycharms] AVISO: %s\n' "$*" >&2; }
fail(){ printf '[pycharms] ERRO: %s\n' "$*" >&2; exit 1; }

find_pycharm_native() {
  local cmd candidate
  for cmd in pycharm pycharm-professional pycharm-community pycharm.sh; do
    if command -v "$cmd" >/dev/null 2>&1; then command -v "$cmd"; return 0; fi
  done
  while IFS= read -r candidate; do
    [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done < <(find /opt "$HOME/.local/share/JetBrains/Toolbox/apps" -maxdepth 8 -type f \( -name pycharm -o -name pycharm.sh \) 2>/dev/null | sort -r)
  return 1
}

pycharm_mode() {
  local native
  if native="$(find_pycharm_native 2>/dev/null)"; then printf 'native\t%s\n' "$native"; return 0; fi
  if command -v snap >/dev/null 2>&1; then
    if snap list pycharm-professional >/dev/null 2>&1; then printf 'snap\tpycharm-professional\n'; return 0; fi
    if snap list pycharm-community >/dev/null 2>&1; then printf 'snap\tpycharm-community\n'; return 0; fi
  fi
  if command -v flatpak >/dev/null 2>&1; then
    if flatpak info com.jetbrains.PyCharm-Professional >/dev/null 2>&1; then printf 'flatpak\tcom.jetbrains.PyCharm-Professional\n'; return 0; fi
    if flatpak info com.jetbrains.PyCharm-Community >/dev/null 2>&1; then printf 'flatpak\tcom.jetbrains.PyCharm-Community\n'; return 0; fi
  fi
  return 1
}

show_diagnose() {
  printf '=== PYCHARM / UBUNTU ===\n'
  printf 'PATH command: '; command -v pycharm || true
  printf 'pycharm-professional: '; command -v pycharm-professional || true
  printf 'pycharm-community: '; command -v pycharm-community || true
  printf '\nCandidatos locais:\n'
  find /opt "$HOME/.local/share/JetBrains/Toolbox/apps" -maxdepth 8 -type f \( -name pycharm -o -name pycharm.sh \) -print 2>/dev/null | sort || true
  printf '\nDetectado pelo comando:\n'; pycharm_mode || printf 'NÃO ENCONTRADO\n'
  printf '\n=== GNOME / MONITOR ===\n'
  [[ -x "$GNOME_WAYLAND_HELPER" ]] && "$GNOME_WAYLAND_HELPER" diagnose || true
  printf '\n=== MAPA PROJETO -> WORKSPACE ===\n'
  load_projects
  write_workspace_map
  cat "$WORKSPACE_MAP"
}

load_projects() {
  [[ -f "$CONFIG_FILE" ]] || fail "configuração não encontrada: $CONFIG_FILE"
  resolved_projects=(); resolved_workspace_indexes=(); resolved_project_names=()
  configured_projects=(); configured_workspace_indexes=(); effective_projects=()
  declare -gA effective_set=(); declare -gA seen_projects=()
  local raw line candidate parent path real skip workspace_index=2

  # Mesma ordem do comando desktops: Workspace 1 é LAZER; cada linha ativa
  # cadastrada ocupa sua posição, mesmo que a pasta ainda não exista.
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"; line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"; line="${line#./}"; line="${line%/}"
    [[ -n "$line" && "${line,,}" != *.zip ]] || continue
    configured_projects+=("$line")
    configured_workspace_indexes+=("$workspace_index")
    ((workspace_index += 1))
  done < "$CONFIG_FILE"

  for line in "${configured_projects[@]}"; do
    path="$CODE_ROOT/$line"
    if [[ ! -d "$path" ]]; then
      warn "fora do grid; projeto ainda ausente: $path"
      continue
    fi
    effective_set[$line]=1
    effective_projects+=("$line")
  done

  local idx
  for ((idx=0; idx<${#configured_projects[@]}; idx++)); do
    line="${configured_projects[$idx]}"
    [[ -n "${effective_set[$line]:-}" ]] || continue
    candidate="$line"; skip=0
    while [[ "$candidate" == */apps/* ]]; do
      parent="${candidate%/apps/*}"
      if [[ -n "${effective_set[$parent]:-}" ]]; then skip=1; break; fi
      candidate="$parent"
    done
    ((skip==0)) || continue

    path="$CODE_ROOT/$line"
    real="$(cd -- "$path" && pwd -P)"
    [[ -z "${seen_projects[$real]:-}" ]] || continue
    seen_projects[$real]=1
    resolved_projects+=("$real")
    resolved_workspace_indexes+=("${configured_workspace_indexes[$idx]}")
    resolved_project_names+=("$(basename -- "$line")")
  done
}

write_workspace_map() {
  mkdir -p "$STATE_DIR"
  local tmp="$WORKSPACE_MAP.tmp.$$" i
  : > "$tmp"
  for ((i=0; i<${#resolved_projects[@]}; i++)); do
    printf '%s\t%s\t%s\n' \
      "${resolved_workspace_indexes[$i]}" \
      "${resolved_project_names[$i]}" \
      "${resolved_projects[$i]}" >> "$tmp"
  done
  mv -f "$tmp" "$WORKSPACE_MAP"
}

show_workspace_map() {
  load_projects
  write_workspace_map
  cat "$WORKSPACE_MAP"
}

request_reconcile() {
  mkdir -p "$STATE_DIR"
  local tmp="$RECONCILE_REQUEST.tmp.$$"
  printf '%s\n' "$(date +%s%N)" > "$tmp"
  mv -f "$tmp" "$RECONCILE_REQUEST"
}

ensure_gnome_workspaces() {
  [[ "${XDG_SESSION_TYPE:-}" == wayland ]] || return 0
  if [[ -x "$DESKTOPS_SCRIPT" ]]; then
    PROJECTS_FILE="$CONFIG_FILE" DESKTOPS_PLATFORM=gnome "$DESKTOPS_SCRIPT" >/dev/null || \
      warn 'não foi possível sincronizar os workspaces antes de abrir o PyCharm'
  fi
  [[ -x "$GNOME_WAYLAND_HELPER" ]] && "$GNOME_WAYLAND_HELPER" ensure || true
}

begin_batch() {
  mkdir -p "$STATE_DIR"
  # Expiração de segurança: se o comando for interrompido, a extensão não fica
  # bloqueada indefinidamente esperando o fim de um lote que morreu.
  printf '%s\n' "$(( $(date +%s) + 180 ))" > "$BATCH_MARKER"
}

finish_batch_later() {
  local settle="$STARTUP_SETTLE_SECONDS"
  [[ "$settle" =~ ^[0-9]+$ ]] || settle=15
  (
    sleep "$settle"
    rm -f -- "$BATCH_MARKER"
    request_reconcile
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
  log "janelas serão reconciliadas após ${settle}s de estabilização (workspace + monitor + maximização)"
}

open_project() {
  local mode="$1" target="$2" project="$3"
  case "$mode" in
    native) nohup "$target" "$project" >/dev/null 2>&1 & ;;
    snap) nohup snap run "$target" "$project" >/dev/null 2>&1 & ;;
    flatpak) nohup flatpak run "$target" "$project" >/dev/null 2>&1 & ;;
  esac
}

case "${1:-}" in
  --diagnose|diagnose) show_diagnose; exit 0 ;;
  --workspace-map|workspace-map) show_workspace_map; exit 0 ;;
  --reconcile|reconcile)
    load_projects
    write_workspace_map
    ensure_gnome_workspaces
    rm -f -- "$BATCH_MARKER"
    request_reconcile
    log 'reconciliação final solicitada.'
    exit 0
    ;;
  --help|-h|help) printf 'Uso: pycharms | pycharms --list | pycharms --workspace-map | pycharms --reconcile | pycharms --diagnose\n'; exit 0 ;;
  --list|list) list_only=1 ;;
  "") list_only=0 ;;
  *) fail "opção inválida: $1" ;;
esac

load_projects
write_workspace_map
if ((list_only)); then printf '%s\n' "${resolved_projects[@]}"; exit 0; fi
((${#resolved_projects[@]})) || fail 'nenhum projeto existente para abrir.'
IFS=$'\t' read -r mode target < <(pycharm_mode) || fail 'PyCharm não encontrado. Rode: pycharms --diagnose'
ensure_gnome_workspaces
if [[ "${XDG_SESSION_TYPE:-}" == wayland ]]; then
  begin_batch
fi
log "Ubuntu backend: $mode -> $target"
for ((i=0; i<${#resolved_projects[@]}; i++)); do
  project="${resolved_projects[$i]}"
  workspace="${resolved_workspace_indexes[$i]}"
  log "abrindo workspace $workspace: $project"
  open_project "$mode" "$target" "$project"
  sleep "$OPEN_DELAY_SECONDS"
done
if [[ "${XDG_SESSION_TYPE:-}" == wayland ]]; then
  finish_batch_later
fi
