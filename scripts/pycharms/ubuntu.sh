#!/usr/bin/env bash
# Backend Ubuntu/Linux do comando `pycharms`.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
CONFIG_FILE="${PYCHARMS_PROJECTS_FILE:-$PROJECT_ROOT/config/auto-code-manager.projects}"
CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
OPEN_DELAY_SECONDS="${PYCHARMS_OPEN_DELAY_SECONDS:-1}"
GNOME_WAYLAND_HELPER="$SCRIPT_DIR/gnome-wayland.sh"
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
  done < <(find \
    /opt \
    "$HOME/.local/share/JetBrains/Toolbox/apps" \
    "$HOME/.local/share/JetBrains/Toolbox/apps/PyCharm-P" \
    "$HOME/.local/share/JetBrains/Toolbox/apps/PyCharm-C" \
    -maxdepth 8 -type f \( -name pycharm -o -name pycharm.sh \) 2>/dev/null | sort -r)
  return 1
}

pycharm_mode() {
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
  printf '\nSnap:\n'; command -v snap >/dev/null 2>&1 && snap list 2>/dev/null | grep -i pycharm || true
  printf '\nFlatpak:\n'; command -v flatpak >/dev/null 2>&1 && flatpak list --app 2>/dev/null | grep -i pycharm || true
  printf '\nDetectado pelo comando:\n'
  pycharm_mode || printf 'NÃO ENCONTRADO\n'
  printf '\n=== GNOME / MONITOR ===\n'
  if [[ -x "$GNOME_WAYLAND_HELPER" ]]; then
    "$GNOME_WAYLAND_HELPER" diagnose || true
  else
    printf 'helper GNOME ausente: %s\n' "$GNOME_WAYLAND_HELPER"
  fi
}

load_projects() {
  [[ -f "$CONFIG_FILE" ]] || fail "configuração não encontrada: $CONFIG_FILE"
  resolved_projects=(); configured_projects=(); effective_projects=()
  declare -gA configured_set=(); declare -gA effective_set=(); declare -gA seen_projects=()
  local raw line candidate parent path real skip

  # 1) Lê a configuração canônica, mas isso ainda NÃO significa que o projeto
  # está ativo no grid. Cadastro sem pasta é somente cadastro pendente.
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"; line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"; line="${line#./}"; line="${line%/}"
    [[ -n "$line" && "${line,,}" != *.zip ]] || continue
    [[ -z "${configured_set[$line]:-}" ]] || continue
    configured_set[$line]=1; configured_projects+=("$line")
  done < "$CONFIG_FILE"

  # 2) Grid efetivo = projeto cadastrado + pasta realmente existente.
  # Ausentes são informados e ignorados; não entram na IDE.
  for line in "${configured_projects[@]}"; do
    path="$CODE_ROOT/$line"
    if [[ ! -d "$path" ]]; then
      warn "fora do grid; projeto ainda ausente: $path"
      continue
    fi
    effective_set[$line]=1
    effective_projects+=("$line")
  done

  # 3) Só um pai EFETIVO pode cobrir <pai>/apps/<filho>. Um pai meramente
  # cadastrado mas inexistente não esconde um filho que existe de verdade.
  for line in "${effective_projects[@]}"; do
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
    seen_projects[$real]=1; resolved_projects+=("$real")
  done
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
  --help|-h|help) printf 'Uso: pycharms | pycharms --list | pycharms --diagnose\n'; exit 0 ;;
  --list|list) list_only=1 ;;
  "") list_only=0 ;;
  *) fail "opção inválida: $1" ;;
esac

load_projects
if ((list_only)); then printf '%s\n' "${resolved_projects[@]}"; exit 0; fi
((${#resolved_projects[@]})) || fail 'nenhum projeto existente para abrir.'
IFS=$'\t' read -r mode target < <(pycharm_mode) || fail 'PyCharm não encontrado. Rode: pycharms --diagnose'
if [[ "${XDG_SESSION_TYPE:-}" == wayland && -x "$GNOME_WAYLAND_HELPER" ]]; then
  "$GNOME_WAYLAND_HELPER" ensure || true
fi
log "Ubuntu backend: $mode -> $target"
for project in "${resolved_projects[@]}"; do
  log "abrindo: $project"
  open_project "$mode" "$target" "$project"
  sleep "$OPEN_DELAY_SECONDS"
done
