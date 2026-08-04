#!/usr/bin/env bash
set -Eeuo pipefail

LOCAL_ROOT="${LOCAL_ROOT:-$HOME/Code}"
DEV_AUTOMATION_REL="bots/dev-automation"
DEV_AUTOMATION_URL="https://github.com/inatto/dev-automation.git"

MANIFEST="${MANIFEST:-$LOCAL_ROOT/$DEV_AUTOMATION_REL/config/environment.repositories}"
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
  done < "$MANIFEST"

  ((active_projects > 0)) || die "nenhum projeto ativo no manifesto"
}


ensure_oracle_wallet() {
  local source_dir="$LOCAL_ROOT/orgs/sind-vault/config/sto_wallet"
  local oracle_dir="$HOME/.oracle"
  local target_dir="$oracle_dir/Wallet_sindicatto"
  local encrypted_file

  if [[ -d "$target_dir" ]]; then
    log "wallet Oracle já existe; cópia ignorada: $target_dir"
    return
  fi

  if [[ ! -d "$source_dir" ]]; then
    warn "origem da wallet não encontrada: $source_dir"
    return
  fi

  encrypted_file="$(
    find "$source_dir" -type f -print0 2>/dev/null |
      while IFS= read -r -d '' file; do
        if LC_ALL=C grep -a -q 'GITCRYPT' "$file" 2>/dev/null; then
          printf '%s' "$file"
          break
        fi
      done
  )"

  if [[ -n "$encrypted_file" ]]; then
    warn "wallet protegida pelo git-crypt ainda está bloqueada: $encrypted_file"
    warn "execute git-crypt unlock no sind-vault e rode o setup novamente"
    return
  fi

  if ! find "$source_dir" -mindepth 1 -print -quit | grep -q .; then
    warn "pasta de origem da wallet está vazia: $source_dir"
    return
  fi

  mkdir -p "$oracle_dir"
  chmod 700 "$oracle_dir"

  mkdir "$target_dir"
  cp -a "$source_dir"/. "$target_dir"/
  chmod 700 "$target_dir"

  log "wallet Oracle instalada em: $target_dir"
}

run_local_command_installer() {
  local candidates=(
    "$LOCAL_ROOT/$DEV_AUTOMATION_REL/deploy/local/install-commands.sh"
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

  mkdir -p "$LOCAL_ROOT"

  ensure_bootstrap_repository
  process_manifest
  ensure_oracle_wallet
  run_local_command_installer

  log "ambiente local conferido com sucesso"
  log "execute: source ~/.bashrc"
}

main "$@"