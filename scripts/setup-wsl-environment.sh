#!/usr/bin/env bash
set -Eeuo pipefail

export GIT_TERMINAL_PROMPT=0

LOCAL_ROOT="${LOCAL_ROOT:-$HOME/Code}"
REMOTE_ROOT="${REMOTE_ROOT:-/home/ubuntu/apps}"
REMOTE_USER="${REMOTE_USER:-ubuntu}"
REMOTE_HOST="${REMOTE_HOST:-52.67.135.170}"
SSH_KEY="${SSH_KEY:-$LOCAL_ROOT/infra/amazon-infra/ec2/52.67.135.170/core/inatto01-sp.pem}"

BOOTSTRAP_PATH="bots/dev-automation"
BOOTSTRAP_URL="https://github.com/inatto/dev-automation.git"
MANIFEST="${MANIFEST:-$LOCAL_ROOT/$BOOTSTRAP_PATH/config/environment.repositories}"

SSH_OPTIONS=(
  -n
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
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

install_base_packages() {
  local packages=()

  command -v git  >/dev/null 2>&1 || packages+=(git)
  command -v ssh  >/dev/null 2>&1 || packages+=(openssh-client)
  command -v scp  >/dev/null 2>&1 || packages+=(openssh-client)
  command -v find >/dev/null 2>&1 || packages+=(findutils)
  command -v cmp  >/dev/null 2>&1 || packages+=(diffutils)

  ((${#packages[@]} == 0)) && return
  command -v apt-get >/dev/null 2>&1 || die "apt-get não encontrado; instale: ${packages[*]}"

  log "instalando dependências básicas: ${packages[*]}"
  sudo apt-get update
  sudo apt-get install -y "${packages[@]}"
}

configure_github_auth() {
  command -v gh >/dev/null 2>&1 || {
    warn "GitHub CLI (gh) não instalado; repositórios privados podem falhar"
    return
  }

  if gh auth status --hostname github.com >/dev/null 2>&1; then
    gh auth setup-git --hostname github.com >/dev/null
  else
    warn "GitHub CLI não autenticado. Execute: gh auth login --hostname github.com --git-protocol https --web"
  fi
}

ensure_bootstrap_repository() {
  local target="$LOCAL_ROOT/$BOOTSTRAP_PATH"
  mkdir -p "$(dirname "$target")"

  if [[ -d "$target/.git" ]]; then
    git -C "$target" remote set-url origin "$BOOTSTRAP_URL"
    return
  fi

  [[ ! -e "$target" ]] || die "existe, mas não é repositório Git: $target"

  log "clonando repositório-base: $BOOTSTRAP_PATH"
  git clone "$BOOTSTRAP_URL" "$target" ||
    die "falha ao clonar $BOOTSTRAP_URL; confirme a autenticação com gh auth status"
}

remote_default_branch() {
  local url="$1"
  local branch

  branch="$(
    git ls-remote --symref "$url" HEAD 2>/dev/null |
      awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }'
  )"

  [[ -n "$branch" ]] ||
    die "não foi possível descobrir a branch padrão: $url"

  printf '%s' "$branch"
}

ensure_repository() {
  local relative="$1"
  local url="$2"
  local target="$LOCAL_ROOT/$relative"
  local branch

  branch="$(remote_default_branch "$url")"
  mkdir -p "$(dirname "$target")"

  if [[ ! -e "$target" ]]; then
    log "clonando $relative ($branch)"
    git clone --branch "$branch" --single-branch "$url" "$target" ||
      die "falha ao clonar $relative; confirme acesso a $url"
    return
  fi

  [[ -d "$target/.git" ]] ||
    die "o caminho existe, mas não contém .git: $target"

  git -C "$target" remote set-url origin "$url"

  if [[ -n "$(git -C "$target" status --porcelain)" ]]; then
    warn "$relative tem alterações locais; origin corrigido e pull ignorado"
    return
  fi

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

remote_project_directory() {
  local relative="$1"
  local without_first_directory="${relative#*/}"

  [[ "$without_first_directory" != "$relative" ]] ||
    die "caminho sem diretório-base: $relative"

  printf '%s/%s' "$REMOTE_ROOT" "$without_first_directory"
}

project_has_env_examples() {
  local project="$1"

  find "$project" \
    -type d -name .git -prune -o \
    -type f -name '.env.example' -print -quit |
    grep -q .
}

check_production_ssh() {
  [[ -f "$SSH_KEY" ]] || die "chave SSH não encontrada: $SSH_KEY"
  chmod 600 "$SSH_KEY"

  ssh "${SSH_OPTIONS[@]}" "$REMOTE_USER@$REMOTE_HOST" 'printf ready' >/dev/null ||
    die "não foi possível acessar $REMOTE_USER@$REMOTE_HOST"
}

sync_project_envs() {
  local relative="$1"
  local local_project="$LOCAL_ROOT/$relative"
  local remote_project
  remote_project="$(remote_project_directory "$relative")"

  while IFS= read -r -d '' example; do
    local directory suffix destination remote_env temporary backup

    directory="$(dirname "$example")"
    suffix="${directory#"$local_project"}"
    destination="$directory/.env"
    remote_env="$remote_project$suffix/.env"

    if ! ssh "${SSH_OPTIONS[@]}" "$REMOTE_USER@$REMOTE_HOST" \
      "test -f $(printf '%q' "$remote_env")"; then
      warn "não existe no servidor: $remote_env"
      continue
    fi

    temporary="$(mktemp "$directory/.env.remote.XXXXXX")"

    if ! scp "${SSH_OPTIONS[@]}" \
      "$REMOTE_USER@$REMOTE_HOST:$remote_env" \
      "$temporary" >/dev/null; then
      rm -f "$temporary"
      warn "falha ao baixar: $remote_env"
      continue
    fi

    chmod 600 "$temporary"

    if [[ -f "$destination" ]] && cmp -s "$temporary" "$destination"; then
      rm -f "$temporary"
      log "env já atualizado: $destination"
      continue
    fi

    if [[ -f "$destination" ]]; then
      backup="${destination}.before-production-sync.$(date +%Y%m%d-%H%M%S)"
      cp -p "$destination" "$backup"
      chmod 600 "$backup"
      log "backup criado: $backup"
    fi

    mv -f "$temporary" "$destination"
    chmod 600 "$destination"
    log "env sincronizado: $remote_env -> $destination"
  done < <(
    find "$local_project" \
      -type d -name .git -prune -o \
      -type f -name '.env.example' -print0
  )
}

process_manifest() {
  [[ -f "$MANIFEST" ]] || die "manifesto não encontrado: $MANIFEST"

  local raw line line_number=0 ssh_checked=0

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line_number=$((line_number + 1))
    line="$(trim "$raw")"

    [[ -z "$line" ]] && continue
    [[ "${line:0:1}" == '#' ]] && continue

    local relative url extra
    IFS='|' read -r relative url extra <<< "$line"

    relative="$(trim "${relative:-}")"
    url="$(trim "${url:-}")"

    [[ -z "${extra:-}" ]] || die "linha $line_number deve ter apenas caminho|git"
    [[ -n "$relative" && -n "$url" ]] || die "linha $line_number inválida"
    [[ "$relative" != /* && "$relative" != *'..'* ]] ||
      die "caminho inseguro na linha $line_number: $relative"
    [[ "$url" == https://github.com/*/*.git ]] ||
      die "URL GitHub inválida na linha $line_number: $url"

    ensure_repository "$relative" "$url"

    local project="$LOCAL_ROOT/$relative"
    if project_has_env_examples "$project"; then
      if ((ssh_checked == 0)); then
        check_production_ssh
        ssh_checked=1
      fi
      sync_project_envs "$relative"
    fi
  done < "$MANIFEST"
}

install_project_commands() {
  local installer="$LOCAL_ROOT/$BOOTSTRAP_PATH/scripts/install-commands.sh"

  if [[ -x "$installer" ]]; then
    log "instalando/atualizando comandos globais"
    "$installer"
  else
    warn "instalador de comandos não encontrado ou não executável: $installer"
  fi
}

main() {
  install_base_packages
  configure_github_auth
  mkdir -p "$LOCAL_ROOT"
  ensure_bootstrap_repository
  process_manifest
  install_project_commands

  log "ambiente conferido com sucesso"
  log "execute: source ~/.bashrc"
}

main "$@"