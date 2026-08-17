#!/usr/bin/env bash
# Backend Ubuntu/Linux do comando `pycharms`.
# Mantido deliberadamente independente do GNOME Shell: abre projetos e não
# instala extensões, não move janelas e não manipula workspaces/monitores.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
CONFIG_FILE="${PYCHARMS_PROJECTS_FILE:-$PROJECT_ROOT/config/auto-code-manager.projects}"
CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
OPEN_DELAY_SECONDS="${PYCHARMS_OPEN_DELAY_SECONDS:-1}"

log(){ printf '[pycharms] %s\n' "$*"; }
warn(){ printf '[pycharms] AVISO: %s\n' "$*" >&2; }
fail(){ printf '[pycharms] ERRO: %s\n' "$*" >&2; exit 1; }

show_help() {
  cat <<'EOF_HELP'
Uso:
  pycharms          Abre os projetos configurados no PyCharm
  pycharms --list   Mostra as pastas que seriam abertas
  pycharms --diagnose  Mostra como o PyCharm foi detectado
  pycharms --help   Mostra esta ajuda

Regra:
  abre os projetos-raiz ativos de auto-code-manager.projects; ignora agregadores
  *.zip, projetos ausentes e subprojetos apps/ quando o pai também está ativo.
  No Ubuntu, o comando não integra com o GNOME Shell nem manipula janelas.
EOF_HELP
}

find_pycharm_native() {
  local cmd candidate
  for cmd in pycharm pycharm-professional pycharm-community pycharm.sh; do
    if command -v "$cmd" >/dev/null 2>&1; then
      command -v "$cmd"
      return 0
    fi
  done

  while IFS= read -r candidate; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(
    find /opt "$HOME/.local/share/JetBrains/Toolbox/apps" \
      -maxdepth 8 -type f \( -name pycharm -o -name pycharm.sh \) \
      2>/dev/null | sort -r
  )
  return 1
}

pycharm_mode() {
  local native
  if native="$(find_pycharm_native 2>/dev/null)"; then
    printf 'native\t%s\n' "$native"
    return 0
  fi

  if command -v snap >/dev/null 2>&1; then
    if snap list pycharm-professional >/dev/null 2>&1; then
      printf 'snap\tpycharm-professional\n'
      return 0
    fi
    if snap list pycharm-community >/dev/null 2>&1; then
      printf 'snap\tpycharm-community\n'
      return 0
    fi
  fi

  if command -v flatpak >/dev/null 2>&1; then
    if flatpak info com.jetbrains.PyCharm-Professional >/dev/null 2>&1; then
      printf 'flatpak\tcom.jetbrains.PyCharm-Professional\n'
      return 0
    fi
    if flatpak info com.jetbrains.PyCharm-Community >/dev/null 2>&1; then
      printf 'flatpak\tcom.jetbrains.PyCharm-Community\n'
      return 0
    fi
  fi

  return 1
}

show_diagnose() {
  printf '=== PYCHARM / UBUNTU ===\n'
  printf 'PATH command: '; command -v pycharm || true
  printf 'pycharm-professional: '; command -v pycharm-professional || true
  printf 'pycharm-community: '; command -v pycharm-community || true
  printf '\nCandidatos locais:\n'
  find /opt "$HOME/.local/share/JetBrains/Toolbox/apps" \
    -maxdepth 8 -type f \( -name pycharm -o -name pycharm.sh \) \
    -print 2>/dev/null | sort || true
  printf '\nDetectado pelo comando:\n'
  pycharm_mode || printf 'NÃO ENCONTRADO\n'
  printf '\nIntegração gráfica: nenhuma. O backend Ubuntu não carrega código no GNOME Shell.\n'
}

load_projects() {
  [[ -f "$CONFIG_FILE" ]] || fail "configuração não encontrada: $CONFIG_FILE"
  [[ -d "$CODE_ROOT" ]] || fail "raiz de projetos não encontrada: $CODE_ROOT"

  configured_projects=()
  effective_projects=()
  resolved_projects=()
  declare -gA configured_set=()
  declare -gA effective_set=()
  declare -gA seen_projects=()

  local raw line project_path candidate parent skip_nested_app project_real_path

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#./}"
    line="${line%/}"
    [[ -n "$line" ]] || continue
    [[ "${line,,}" == *.zip ]] && continue

    if [[ -z "${configured_set["$line"]:-}" ]]; then
      configured_set["$line"]=1
      configured_projects+=("$line")
    fi
  done < "$CONFIG_FILE"

  for line in "${configured_projects[@]}"; do
    project_path="$CODE_ROOT/$line"
    if [[ ! -d "$project_path" ]]; then
      warn "fora do grid; projeto ainda ausente: $project_path"
      continue
    fi
    effective_set["$line"]=1
    effective_projects+=("$line")
  done

  for line in "${effective_projects[@]}"; do
    candidate="$line"
    skip_nested_app=0
    while [[ "$candidate" == */apps/* ]]; do
      parent="${candidate%/apps/*}"
      if [[ -n "${effective_set["$parent"]:-}" ]]; then
        skip_nested_app=1
        break
      fi
      candidate="$parent"
    done
    ((skip_nested_app == 0)) || continue

    project_path="$CODE_ROOT/$line"
    project_real_path="$(cd -- "$project_path" && pwd -P)"
    if [[ -z "${seen_projects["$project_real_path"]:-}" ]]; then
      seen_projects["$project_real_path"]=1
      resolved_projects+=("$project_real_path")
    fi
  done
}

open_project() {
  local mode="$1" target="$2" project="$3"
  case "$mode" in
    native) nohup "$target" "$project" >/dev/null 2>&1 & ;;
    snap) nohup snap run "$target" "$project" >/dev/null 2>&1 & ;;
    flatpak) nohup flatpak run "$target" "$project" >/dev/null 2>&1 & ;;
    *) fail "modo PyCharm inválido: $mode" ;;
  esac
}

case "${1:-}" in
  --help|-h|help)
    show_help
    exit 0
    ;;
  --diagnose|diagnose)
    show_diagnose
    exit 0
    ;;
  --list|list)
    list_only=1
    ;;
  "")
    list_only=0
    ;;
  *)
    fail "opção inválida: $1 (use --help)"
    ;;
esac

load_projects
((${#resolved_projects[@]} > 0)) || fail 'nenhum projeto existente no grid efetivo.'

if ((list_only == 1)); then
  printf '%s\n' "${resolved_projects[@]}"
  exit 0
fi

IFS=$'\t' read -r mode target < <(pycharm_mode) || fail 'PyCharm não encontrado. Rode: pycharms --diagnose'
log "Ubuntu backend: $mode -> $target"
log "abrindo ${#resolved_projects[@]} projeto(s) sem integração com o GNOME Shell"

for project in "${resolved_projects[@]}"; do
  log "abrindo: $project"
  open_project "$mode" "$target" "$project"
  sleep "$OPEN_DELAY_SECONDS"
done
