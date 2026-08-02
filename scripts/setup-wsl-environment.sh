#!/usr/bin/env bash
set -Eeuo pipefail

LOCAL_ROOT="${LOCAL_ROOT:-$HOME/Code}"
REMOTE_ROOT="${REMOTE_ROOT:-/home/ubuntu/apps}"
REMOTE_USER="${REMOTE_USER:-ubuntu}"
REMOTE_HOST="${REMOTE_HOST:-52.67.135.170}"

DEV_AUTOMATION_REL="bots/dev-automation"
DEV_AUTOMATION_URL="https://github.com/inatto/dev-automation.git"

MANIFEST="${MANIFEST:-$LOCAL_ROOT/$DEV_AUTOMATION_REL/config/environment.repositories}"
SSH_KEY="${SSH_KEY:-$LOCAL_ROOT/infra/amazon-infra/ec2/52.67.135.170/core/inatto01-sp.pem}"

SSH_OPTS=(
  -n
  -i "$SSH_KEY"
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=120
  -o TCPKeepAlive=yes
  -o StrictHostKeyChecking=accept-new
)

SCP_OPTS=(
  -i "$SSH_KEY"
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=120
  -o TCPKeepAlive=yes
  -o StrictHostKeyChecking=accept-new
)

log()  { printf '[environment] %s\n' "$*"; }
warn() { printf '[environment] AVISO: %s\n' "$*" >&2; }
die()  { printf '[environment] ERRO: %s\n' "$*" >&2; exit 1; }

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "comando obrigatório não encontrado: $1"
}

install_base_packages() {
  local packages=()

  command -v git >/dev/null 2>&1 || packages+=(git)
  command -v ssh >/dev/null 2>&1 || packages+=(openssh-client)
  command -v scp >/dev/null 2>&1 || packages+=(openssh-client)
  command -v find >/dev/null 2>&1 || packages+=(findutils)
  command -v cmp >/dev/null 2>&1 || packages+=(diffutils)
  command -v mktemp >/dev/null 2>&1 || packages+=(coreutils)

  ((${#packages[@]} == 0)) && return

  command -v apt-get >/dev/null 2>&1 ||
    die "faltam pacotes e apt-get não está disponível: ${packages[*]}"

  log "instalando pacotes básicos: ${packages[*]}"
  sudo apt-get update
  sudo apt-get install -y "${packages[@]}"
}

resolve_default_branch() {
  local url="$1"
  local branch

  branch="$(
    git ls-remote --symref "$url" HEAD 2>/dev/null |
      awk '/^ref:/ {
        sub("^refs/heads/", "", $2)
        print $2
        exit
      }'
  )"

  [[ -n "$branch" ]] || return 1
  printf '%s' "$branch"
}

ensure_repository() {
  local relative="$1"
  local url="$2"
  local target="$LOCAL_ROOT/$relative"
  local branch

  mkdir -p "$(dirname "$target")"

  if [[ ! -e "$target" ]]; then
    branch="$(resolve_default_branch "$url")" ||
      die "não foi possível descobrir a branch padrão: $url"

    log "clonando $relative ($branch)"
    git clone --branch "$branch" --single-branch "$url" "$target"
    return
  fi

  [[ -d "$target/.git" ]] ||
    die "o caminho existe, mas não é repositório Git: $target"

  git -C "$target" remote set-url origin "$url"

  if [[ -n "$(git -C "$target" status --porcelain)" ]]; then
    warn "$relative tem alterações locais; origin corrigido e pull ignorado"
    return
  fi

  branch="$(resolve_default_branch "$url")" ||
    die "não foi possível descobrir a branch padrão: $url"

  log "atualizando $relative ($branch)"
  git -C "$target" fetch --prune origin

  local current_branch
  current_branch="$(git -C "$target" branch --show-current)"

  if [[ "$current_branch" != "$branch" ]]; then
    if git -C "$target" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$target" switch "$branch"
    else
      git -C "$target" switch --track -c "$branch" "origin/$branch"
    fi
  fi

  git -C "$target" pull --ff-only origin "$branch"
}

check_remote_access() {
  [[ -f "$SSH_KEY" ]] || die "chave SSH não encontrada: $SSH_KEY"
  chmod 600 "$SSH_KEY"

  ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" 'printf ready' >/dev/null ||
    die "não foi possível acessar $REMOTE_USER@$REMOTE_HOST"
}

remote_file_exists() {
  local remote_file="$1"
  ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" test -f "$remote_file"
}

download_remote_file() {
  local remote_file="$1"
  local local_file="$2"

  scp "${SCP_OPTS[@]}"     "$REMOTE_USER@$REMOTE_HOST:$remote_file"     "$local_file"
}

sync_one_env() {
  local project_relative="$1"
  local project_local="$2"
  local example_file="$3"

  local example_relative="${example_file#"$project_local"/}"
  local env_relative

  case "$(basename "$example_file")" in
    .env.example)
      env_relative="${example_relative%/.env.example}/.env"
      ;;
    .env.sample)
      env_relative="${example_relative%/.env.sample}/.env"
      ;;
    *)
      return
      ;;
  esac

  local local_env="$project_local/$env_relative"
  local remote_env="$REMOTE_ROOT/$project_relative/$env_relative"

  if ! remote_file_exists "$remote_env"; then
    warn "não existe no servidor: $remote_env"
    return
  fi

  mkdir -p "$(dirname "$local_env")"

  local temporary
  temporary="$(mktemp)"

  if ! download_remote_file "$remote_env" "$temporary"; then
    rm -f "$temporary"
    warn "falha ao baixar: $remote_env"
    return
  fi

  chmod 600 "$temporary"

  if [[ -f "$local_env" ]] && cmp -s "$temporary" "$local_env"; then
    rm -f "$temporary"
    log "env já atualizado: $local_env"
    return
  fi

  if [[ -f "$local_env" ]]; then
    local backup="${local_env}.before-production-sync.$(date +%Y%m%d-%H%M%S)"
    cp -p "$local_env" "$backup"
    log "backup local criado: $backup"
  fi

  mv "$temporary" "$local_env"
  chmod 600 "$local_env"
  log "env sincronizado: $remote_env -> $local_env"
}

sync_project_envs() {
  local project_relative="$1"
  local project_local="$LOCAL_ROOT/$project_relative"
  local found=0

  while IFS= read -r -d '' example_file; do
    found=1
    sync_one_env "$project_relative" "$project_local" "$example_file"
  done < <(
    find "$project_local"       -type d -name .git -prune -o       -type d \( -name node_modules -o -name .venv -o -name venv \) -prune -o       -type f \( -name '.env.example' -o -name '.env.sample' \)       -print0
  )

  if ((found == 0)); then
    log "nenhum .env.example/.env.sample em: $project_relative"
  fi
}

ensure_bootstrap_repository() {
  local target="$LOCAL_ROOT/$DEV_AUTOMATION_REL"

  mkdir -p "$(dirname "$target")"

  if [[ -d "$target/.git" ]]; then
    git -C "$target" remote set-url origin "$DEV_AUTOMATION_URL"
    return
  fi

  [[ ! -e "$target" ]] || die "o caminho-base existe, mas não é Git: $target"

  log "clonando repositório-base: $DEV_AUTOMATION_REL"
  git clone "$DEV_AUTOMATION_URL" "$target"
}

process_manifest() {
  [[ -f "$MANIFEST" ]] || die "manifesto não encontrado: $MANIFEST"

  local line_number=0
  local active_projects=0
  local raw_line line relative url extra

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    ((line_number += 1))

    line="$(trim "$raw_line")"
    [[ -z "$line" ]] && continue
    [[ "${line:0:1}" == "#" ]] && continue

    relative=""
    url=""
    extra=""

    IFS='|' read -r relative url extra <<<"$line"

    relative="$(trim "$relative")"
    url="$(trim "$url")"
    extra="$(trim "$extra")"

    [[ -n "$relative" && -n "$url" ]] ||
      die "linha $line_number inválida; esperado: caminho|url"

    [[ -z "$extra" ]] ||
      die "linha $line_number tem campos extras; esperado somente: caminho|url"

    [[ "$relative" != /* ]] ||
      die "linha $line_number usa caminho absoluto: $relative"

    [[ "$relative" != *".."* ]] ||
      die "linha $line_number contém caminho inseguro: $relative"

    [[ "$url" == https://github.com/*.git ]] ||
      die "linha $line_number tem URL GitHub inválida: $url"

    ((active_projects += 1))

    ensure_repository "$relative" "$url"
    sync_project_envs "$relative"
  done < "$MANIFEST"

  ((active_projects > 0)) || die "nenhum projeto ativo no manifesto"
}

run_local_command_installer() {
  local candidates=(
    "$LOCAL_ROOT/$DEV_AUTOMATION_REL/scripts/install-commands.sh"
    "$LOCAL_ROOT/$DEV_AUTOMATION_REL/install-commands.sh"
  )

  local installer
  for installer in "${candidates[@]}"; do
    if [[ -x "$installer" ]]; then
      log "instalando/atualizando comandos locais"
      "$installer"
      return
    fi
  done

  warn "instalador de comandos não encontrado ou não executável"
}

main() {
  install_base_packages

  require_command git
  require_command ssh
  require_command scp
  require_command find
  require_command cmp
  require_command mktemp

  mkdir -p "$LOCAL_ROOT"

  ensure_bootstrap_repository
  check_remote_access
  process_manifest
  run_local_command_installer

  log "ambiente local conferido com sucesso"
  log "o servidor remoto foi usado somente para leitura"
  log "execute: source ~/.bashrc"
}

main "$@"