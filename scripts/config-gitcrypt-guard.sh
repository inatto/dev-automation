#!/usr/bin/env bash
# Dev-manager git-crypt guard: SOMENTE desbloqueia repositórios existentes
# usando a chave padrão. Não cria/edita .gitattributes, não altera índice Git,
# não executa git add e não inicializa git-crypt.

set -uo pipefail

CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
PROJECTS_FILE="${DEV_MANAGER_PROJECTS_FILE:-}"
KEY_FILE="${DEV_MANAGER_GIT_CRYPT_KEY:-/home/daniel/static/reverse-crypt.key}"
MODE="unlock"
ONLY_PROJECT=""
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/project-config.sh
source "$PROJECT_ROOT/scripts/lib/project-config.sh"
PROJECTS_FILE="${PROJECTS_FILE:-$(dev_projects_file "$PROJECT_ROOT")}"
CRITICALS=0
UNLOCKED=0
WARNINGS=0

usage() {
  cat <<'EOF_HELP'
Uso:
  config-gitcrypt-guard.sh [--unlock|--check] [--project REL] [--code-root DIR]
                           [--projects-file FILE] [--key FILE]

Padrão: --unlock usando /home/daniel/static/reverse-crypt.key.

IMPORTANTE: este script NÃO cria nem altera .gitattributes, NÃO altera o índice
Git, NÃO faz git add e NÃO executa git-crypt init. A única ação mutável é:
  git-crypt unlock /home/daniel/static/reverse-crypt.key
EOF_HELP
}

out() { printf '%s: %s\n' "$1" "$2"; }
critical() { CRITICALS=$((CRITICALS + 1)); out CRITICAL "$*"; }
warn() { WARNINGS=$((WARNINGS + 1)); out AVISO "$*"; }
ok() { out OK "$*"; }
detail() { out DETALHE "$*"; }
unlocked() { UNLOCKED=$((UNLOCKED + 1)); out UNLOCK "$*"; }

trim_line() {
  local line="$1"
  line="${line%$'\r'}"
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  printf '%s\n' "$line"
}

is_aggregate_project() { [[ "${1,,}" == *.zip ]]; }
project_selected() { local project="$1"; [ -z "$ONLY_PROJECT" ] || [ "$project" = "$ONLY_PROJECT" ]; }

find_config_dirs() {
  local root="$1" dir
  while IFS= read -r -d '' dir; do
    # Não classifica src/config como segredo só pelo nome.
    if [ "$dir" = "$root/config" ]; then
      printf '%s\n' "$dir"
      continue
    fi
    if [ -d "$dir/local" ] || [ -d "$dir/remote" ] || [ -d "$dir/production" ]; then
      printf '%s\n' "$dir"
      continue
    fi
    if find "$dir" -maxdepth 1 -type f \
      \( -name '.env' -o -name '.env.*' -o -iname '*.ini' -o -iname '*.conf' -o \
         -iname '*.cfg' -o -iname '*.properties' -o -iname 'credentials*' -o -iname 'secrets*' \) \
      -print -quit 2>/dev/null | grep -q .; then
      printf '%s\n' "$dir"
    fi
  done < <(find "$root" \
    \( -type d \( \
      -name .git -o -name node_modules -o -name .venv -o -name venv -o \
      -name __pycache__ -o -name .pytest_cache -o -name .cache -o \
      -name dist -o -name build -o -name target -o -name vendor -o \
      -name .idea -o -name .astro \
    \) -prune \) -o \
    \( -type d -iname config -print0 \) 2>/dev/null)
}

repo_internal_key_matches() {
  local repo="$1" tmp
  tmp="$(mktemp)" || return 2
  if git -C "$repo" crypt export-key "$tmp" >/dev/null 2>&1; then
    if cmp -s -- "$tmp" "$KEY_FILE"; then
      rm -f -- "$tmp"
      return 0
    fi
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp"
  return 2
}

unlock_repo_only() {
  local repo="$1" state unlock_err=""
  shift
  local -a config_dirs=("$@")

  repo_internal_key_matches "$repo"
  state=$?
  case "$state" in
    0)
      ok "$repo: git-crypt já desbloqueado com a chave padrão"
      ;;
    1)
      critical "$repo: git-crypt está desbloqueado com outra chave; não alterado"
      ;;
    2)
      if [ "$MODE" = check ]; then
        critical "$repo: git-crypt ainda não está desbloqueado com a chave padrão"
      else
        unlock_err="$(git -C "$repo" crypt unlock "$KEY_FILE" 2>&1 >/dev/null || true)"
        if repo_internal_key_matches "$repo"; then
          unlocked "$repo: git-crypt desbloqueado com $KEY_FILE"
        else
          unlock_err="${unlock_err//$'\n'/; }"
          [ -n "$unlock_err" ] || unlock_err="git-crypt recusou a chave sem detalhar o motivo"
          critical "$repo: não foi possível executar git-crypt unlock com a chave padrão | motivo: $unlock_err"
        fi
      fi
      ;;
  esac

  detail "pastas config encontradas neste repo:"
  local cfg
  for cfg in "${config_dirs[@]}"; do
    detail "  - $cfg"
  done
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --unlock) MODE=unlock; shift ;;
    --check) MODE=check; shift ;;
    --fix)
      printf 'ERRO: --fix foi removido. Este guard só faz git-crypt unlock; não cria/edita atributos Git.\n' >&2
      exit 2
      ;;
    --project)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      ONLY_PROJECT="${2#./}"; ONLY_PROJECT="${ONLY_PROJECT%/}"; shift 2 ;;
    --code-root)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      CODE_ROOT="$2"; shift 2 ;;
    --projects-file)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      PROJECTS_FILE="$2"; shift 2 ;;
    --key)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      KEY_FILE="$2"; shift 2 ;;
    -h|--help|help) usage; exit 0 ;;
    *) printf 'ERRO: argumento inválido: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -d "$CODE_ROOT" ] || { critical "CODE_ROOT não existe: $CODE_ROOT"; exit 3; }
[ -f "$PROJECTS_FILE" ] || { critical "arquivo de projetos não existe: $PROJECTS_FILE"; exit 3; }
command -v git >/dev/null 2>&1 || { critical "git não instalado"; exit 3; }
command -v git-crypt >/dev/null 2>&1 || {
  critical "git-crypt não instalado"
  out INSTALAR "sudo apt update && sudo apt install -y git-crypt"
  exit 3
}
[ -r "$KEY_FILE" ] || { critical "chave git-crypt ausente ou ilegível: $KEY_FILE"; exit 3; }

declare -A REPO_CONFIGS=()
declare -A SEEN_CONFIGS=()
FOUND_CONFIGS=0

while IFS= read -r raw || [ -n "$raw" ]; do
  project="$(trim_line "$raw")"
  [ -n "$project" ] || continue
  project="${project#./}"; project="${project%/}"
  is_aggregate_project "$project" && continue
  project_selected "$project" || continue
  project_dir="$CODE_ROOT/$project"
  if [ ! -d "$project_dir" ]; then
    warn "projeto ativo ainda não existe nesta máquina: $project_dir"
    continue
  fi

  while IFS= read -r config_dir || [ -n "$config_dir" ]; do
    [ -n "$config_dir" ] || continue
    config_real="$(readlink -f -- "$config_dir" 2>/dev/null || true)"
    [ -n "$config_real" ] || continue
    [ -z "${SEEN_CONFIGS[$config_real]+x}" ] || continue
    SEEN_CONFIGS["$config_real"]=1
    FOUND_CONFIGS=$((FOUND_CONFIGS + 1))

    repo="$(git -C "$config_real" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$repo" ]; then
      critical "pasta config não pertence a repositório Git: $config_real"
      continue
    fi
    repo="$(readlink -f -- "$repo")"
    if [ -n "${REPO_CONFIGS[$repo]-}" ]; then
      REPO_CONFIGS["$repo"]+=$'\n'"$config_real"
    else
      REPO_CONFIGS["$repo"]="$config_real"
    fi
  done < <(find_config_dirs "$project_dir")
done < "$PROJECTS_FILE"

if [ "$FOUND_CONFIGS" -eq 0 ]; then
  [ -z "$ONLY_PROJECT" ] || ok "nenhuma pasta config encontrada no projeto ativo: $ONLY_PROJECT"
  out RESUMO "0 críticos, 0 unlock(s), $WARNINGS aviso(s), 0 pastas config examinadas"
  exit 0
fi

for repo in "${!REPO_CONFIGS[@]}"; do
  mapfile -t configs < <(printf '%s\n' "${REPO_CONFIGS[$repo]}" | sed '/^$/d' | sort -u)
  unlock_repo_only "$repo" "${configs[@]}"
done

if [ "$CRITICALS" -gt 0 ]; then
  out RESUMO "$CRITICALS crítico(s), $UNLOCKED unlock(s), $WARNINGS aviso(s), $FOUND_CONFIGS pasta(s) config examinada(s)"
  exit 3
fi
out RESUMO "0 críticos, $UNLOCKED unlock(s), $WARNINGS aviso(s), $FOUND_CONFIGS pasta(s) config examinada(s)"
exit 0
