#!/usr/bin/env bash
# Abre SSH do servidor remoto de um projeto, com diagnóstico leve antes da sessão.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CLEAR_TERMINAL="$SCRIPT_DIR/clear-terminal.sh"

COMMAND_NAME="${1:-}"
PROJECT_DIR="${2:-}"
PROJECT_REL="${3:-}"
CODE_ROOT="${4:-/home/daniel/Code}"
shift 4 || true
SSH_EXTRA_ARGS=("$@")

fail() {
  printf '[%s] ERRO: %s\n' "${COMMAND_NAME:-ssh-project}" "$*" >&2
  exit 1
}

warn() {
  printf '[%s] AVISO: %s\n' "$COMMAND_NAME" "$*" >&2
}

log() {
  printf '[%s] %s\n' "$COMMAND_NAME" "$*"
}

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

strip_shell_value() {
  local value
  value="$(trim "${1:-}")"
  case "$value" in
    \"*) value="${value#\"}"; value="${value%%\"*}" ;;
    \'*) value="${value#\'}"; value="${value%%\'*}" ;;
    *) value="${value%%[[:space:]]#*}"; value="$(trim "$value")" ;;
  esac
  printf '%s\n' "$value"
}

is_unresolved_shell_value() {
  local value="${1:-}" check
  check="${value//\$\{HOME\}/}"
  check="${check//\$HOME/}"
  [[ "$check" == *'$('* || "$check" == *'${'* || "$check" == *'`'* ]]
}

extract_assignment() {
  local file="$1"
  shift
  local key line value
  [[ -f "$file" ]] || return 1
  for key in "$@"; do
    line="$(grep -m1 -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$file" 2>/dev/null || true)"
    [[ -n "$line" ]] || continue
    value="${line#*=}"
    value="$(strip_shell_value "$value")"
    [[ -n "$value" ]] || continue
    is_unresolved_shell_value "$value" && continue
    printf '%s\n' "$value"
    return 0
  done
  return 1
}

expand_known_path() {
  local value="${1:-}"
  value="${value//\$HOME/$HOME}"
  value="${value//\$\{HOME\}/$HOME}"
  value="${value//\~\//$HOME/}"
  printf '%s\n' "$value"
}

normalize_site_url() {
  local value="${1:-}"
  value="$(trim "$value")"
  [[ -n "$value" ]] || return 1
  case "$value" in
    http://*|https://*) printf '%s\n' "$value" ;;
    *) printf 'https://%s/\n' "${value%/}" ;;
  esac
}

append_site() {
  local site="${1:-}" existing
  [[ -n "$site" ]] || return 0
  site="$(normalize_site_url "$site")" || return 0
  for existing in "${SITE_URLS[@]:-}"; do
    [[ "$existing" == "$site" ]] && return 0
  done
  SITE_URLS+=("$site")
}

project_candidate_files() {
  local dir
  for dir in \
    "$PROJECT_DIR/deploy/remote" \
    "$PROJECT_DIR/config/remote" \
    "$PROJECT_DIR/config/production"; do
    [[ -d "$dir" ]] || continue
    find "$dir" -maxdepth 2 -type f \
      \( -name '*.sh' -o -name '*.env' -o -name '.env*' -o -name '*.env.*' -o -name '*.conf' -o -name '*.ini' \) \
      -print 2>/dev/null
  done | sort -u
}

REMOTE_USER_SOURCE=""
REMOTE_HOST_SOURCE=""
SSH_KEY_SOURCE=""
SSH_PORT_SOURCE=""
SEARCHED_PROJECT_FILES=()
AMAZON_INFRA_ROOT=""
AMAZON_SELECTED_FILE=""

resolve_from_project_files() {
  local file value
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    SEARCHED_PROJECT_FILES+=("$file")

    if [[ -z "$REMOTE_USER" ]]; then
      value="$(extract_assignment "$file" REMOTE_USER SSH_USER SERVER_USER DEPLOY_USER 2>/dev/null || true)"
      if [[ -n "$value" ]]; then REMOTE_USER="$value"; REMOTE_USER_SOURCE="$file"; fi
    fi
    if [[ -z "$REMOTE_HOST" ]]; then
      value="$(extract_assignment "$file" REMOTE_HOST SSH_HOST SERVER_HOST SERVER_IP REMOTE_IP EC2_HOST EC2_IP 2>/dev/null || true)"
      if [[ -n "$value" ]]; then REMOTE_HOST="$value"; REMOTE_HOST_SOURCE="$file"; fi
    fi
    if [[ -z "$SSH_KEY" ]]; then
      value="$(extract_assignment "$file" SSH_KEY SSH_KEY_PATH SSH_PRIVATE_KEY PEM_FILE KEY_FILE 2>/dev/null || true)"
      if [[ -n "$value" ]]; then SSH_KEY="$(expand_known_path "$value")"; SSH_KEY_SOURCE="$file"; fi
    fi
    if [[ -z "$SSH_PORT" ]]; then
      value="$(extract_assignment "$file" SSH_PORT 2>/dev/null || true)"
      if [[ -n "$value" ]]; then SSH_PORT="$value"; SSH_PORT_SOURCE="$file"; fi
    fi

    value="$(extract_assignment "$file" SITE_URL REMOTE_URL PUBLIC_URL APP_URL 2>/dev/null || true)"
    [[ -n "$value" ]] && append_site "$value"
    value="$(extract_assignment "$file" SITE_NAME DOMAIN 2>/dev/null || true)"
    [[ -n "$value" ]] && append_site "$value"
  done < <(project_candidate_files)
}

amazon_match_score() {
  local file="$1" app_name remote_app_dir basename_project score=0
  basename_project="$(basename -- "$PROJECT_REL")"
  app_name="$(extract_assignment "$file" APP_NAME 2>/dev/null || true)"
  remote_app_dir="$(extract_assignment "$file" REMOTE_APP_DIR 2>/dev/null || true)"

  if [[ -n "$remote_app_dir" && "$remote_app_dir" == */"$PROJECT_REL" ]]; then
    score=100
  elif [[ -n "$app_name" && "$app_name" == "$basename_project" ]]; then
    score=80
  elif grep -Fq "\"/$basename_project/" "$file" 2>/dev/null; then
    score=70
  fi

  if ((score > 0)) && [[ "$file" == */ec2/* ]]; then
    ((score += 10))
  fi
  printf '%d\n' "$score"
}

resolve_from_amazon_infra() {
  local infra_root file score best_score=-1 best_file="" value selected_host=""
  local -a files=()
  infra_root="${DEV_AUTOMATION_AMAZON_INFRA_DIR:-$CODE_ROOT/infra/amazon-infra}"
  AMAZON_INFRA_ROOT="$infra_root"
  [[ -d "$infra_root" ]] || return 0

  while IFS= read -r file; do
    [[ -n "$file" ]] && files+=("$file")
  done < <(
    find "$infra_root/ec2" "$infra_root/lightsail" -type f -path '*/domains/*.conf' -print 2>/dev/null | sort
  )

  for file in "${files[@]}"; do
    score="$(amazon_match_score "$file")"
    ((score > best_score)) || continue
    best_score="$score"
    best_file="$file"
  done

  ((best_score > 0)) || return 0
  AMAZON_SELECTED_FILE="$best_file"

  if [[ -z "$REMOTE_USER" ]]; then
    REMOTE_USER="$(extract_assignment "$best_file" REMOTE_USER SSH_USER 2>/dev/null || true)"
    [[ -n "$REMOTE_USER" ]] && REMOTE_USER_SOURCE="$best_file"
  fi
  if [[ -z "$REMOTE_HOST" ]]; then
    REMOTE_HOST="$(extract_assignment "$best_file" REMOTE_HOST SSH_HOST 2>/dev/null || true)"
    [[ -n "$REMOTE_HOST" ]] && REMOTE_HOST_SOURCE="$best_file"
  fi
  if [[ -z "$SSH_KEY" ]]; then
    value="$(extract_assignment "$best_file" SSH_KEY SSH_KEY_PATH 2>/dev/null || true)"
    if [[ -n "$value" ]]; then SSH_KEY="$(expand_known_path "$value")"; SSH_KEY_SOURCE="$best_file"; fi
  fi
  selected_host="$REMOTE_HOST"

  # Mostra todos os sites atuais que apontam para o mesmo projeto e servidor.
  for file in "${files[@]}"; do
    score="$(amazon_match_score "$file")"
    ((score > 0)) || continue
    value="$(extract_assignment "$file" REMOTE_HOST SSH_HOST 2>/dev/null || true)"
    [[ -z "$selected_host" || "$value" == "$selected_host" ]] || continue

    value="$(extract_assignment "$file" SITE_NAME DOMAIN 2>/dev/null || true)"
    if [[ -n "$value" ]]; then
      if grep -Fq "\"/$(basename -- "$PROJECT_REL")/" "$file" 2>/dev/null \
         && [[ "$(extract_assignment "$file" APP_NAME 2>/dev/null || true)" != "$(basename -- "$PROJECT_REL")" ]]; then
        append_site "https://${value%/}/$(basename -- "$PROJECT_REL")/"
      else
        append_site "$value"
      fi
    fi
  done
}

http_health() {
  local url="$1" result code elapsed
  command -v curl >/dev/null 2>&1 || {
    log "site: curl não instalado; diagnóstico HTTP ignorado ($url)"
    return 0
  }

  if result="$(curl -sS -L -o /dev/null --connect-timeout 4 --max-time 10 \
      -w '%{http_code} %{time_total}' "$url" 2>/dev/null)"; then
    code="${result%% *}"
    elapsed="${result#* }"
    case "$code" in
      2??|3??) log "site OK: HTTP $code em ${elapsed}s | $url" ;;
      *) log "site ATENÇÃO: HTTP $code em ${elapsed}s | $url" ;;
    esac
  else
    log "site INDISPONÍVEL/SEM RESPOSTA: $url"
  fi
}

build_ssh_args() {
  SSH_ARGS=(
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=120
    -o TCPKeepAlive=yes
    -o ConnectTimeout=8
  )
  if [[ -n "$SSH_KEY" ]]; then
    if [[ -f "$SSH_KEY" ]]; then
      SSH_ARGS+=( -i "$SSH_KEY" )
    else
      warn "chave configurada não existe nesta máquina: $SSH_KEY"
      [[ -z "$SSH_KEY_SOURCE" ]] || warn "chave obtida de: $SSH_KEY_SOURCE"
      warn "tentando agente/configuração SSH padrão"
    fi
  fi
  [[ -z "$SSH_PORT" ]] || SSH_ARGS+=( -p "$SSH_PORT" )
  SSH_ARGS+=("${SSH_EXTRA_ARGS[@]}")
}

remote_preflight() {
  local destination="$1" output status=0
  output="$(ssh "${SSH_ARGS[@]}" -o BatchMode=yes "$destination" \
    'printf "host=%s\\n" "$(hostname)"; printf "uptime="; uptime -p 2>/dev/null || uptime; printf "load="; awk "{print \$1, \$2, \$3}" /proc/loadavg 2>/dev/null || true; printf "disk_root="; df -hP / 2>/dev/null | awk "NR==2 {print \$3 \"/\" \$2 \" (\" \$5 \")\"}"' \
    2>/dev/null)" || status=$?

  if ((status == 0)); then
    log "SSH OK: $destination"
    while IFS= read -r line; do
      [[ -n "$line" ]] && printf '  %s\n' "$line"
    done <<< "$output"
  else
    warn "pré-teste SSH não autenticou (código $status); a sessão interativa ainda será tentada"
  fi
}

[[ -n "$COMMAND_NAME" ]] || fail "nome do comando não informado"
[[ -n "$PROJECT_DIR" ]] || fail "diretório do projeto não informado"
[[ -n "$PROJECT_REL" ]] || fail "caminho lógico do projeto não informado"
[[ -d "$PROJECT_DIR" ]] || fail "projeto configurado não existe: $PROJECT_DIR"
command -v ssh >/dev/null 2>&1 || fail "cliente ssh não encontrado"

if [[ "${DEV_AUTOMATION_SKIP_CLEAR:-0}" != "1" && -f "$CLEAR_TERMINAL" ]]; then
  bash "$CLEAR_TERMINAL"
fi

REMOTE_USER=""
REMOTE_HOST=""
SSH_KEY=""
SSH_PORT=""
SITE_URLS=()
SSH_ARGS=()

resolve_from_project_files
resolve_from_amazon_infra

if [[ -z "$REMOTE_HOST" ]]; then
  warn "não consegui identificar o servidor remoto. Locais pesquisados:"
  printf '  - %s\n' "$PROJECT_DIR/deploy/remote" "$PROJECT_DIR/config/remote" "$PROJECT_DIR/config/production" >&2
  [[ -z "$AMAZON_INFRA_ROOT" ]] || printf '  - %s (amazon-infra)\n' "$AMAZON_INFRA_ROOT" >&2
  fail "servidor remoto não encontrado"
fi
if [[ "$REMOTE_HOST" == *@* ]]; then
  [[ -n "$REMOTE_USER" ]] || REMOTE_USER="${REMOTE_HOST%@*}"
  REMOTE_HOST="${REMOTE_HOST#*@}"
fi
[[ -n "$REMOTE_USER" ]] || REMOTE_USER="ubuntu"
[[ "$SSH_PORT" =~ ^[0-9]*$ ]] || fail "SSH_PORT inválida: $SSH_PORT"

destination="$REMOTE_USER@$REMOTE_HOST"
log "projeto: $PROJECT_REL"
log "servidor: $destination${SSH_PORT:+:$SSH_PORT}"
[[ -z "$REMOTE_HOST_SOURCE" ]] || log "origem do servidor: $REMOTE_HOST_SOURCE"
if [[ -n "$SSH_KEY" ]]; then
  log "chave SSH: $SSH_KEY"
  [[ -z "$SSH_KEY_SOURCE" ]] || log "origem da chave: $SSH_KEY_SOURCE"
else
  log "chave SSH: não configurada; usando ssh-agent/~/.ssh/config se disponível"
fi
log "procurado no projeto: $PROJECT_DIR/deploy/remote, $PROJECT_DIR/config/remote, $PROJECT_DIR/config/production"
[[ -z "$AMAZON_INFRA_ROOT" ]] || log "procurado na infra: $AMAZON_INFRA_ROOT"
[[ -z "$AMAZON_SELECTED_FILE" ]] || log "config remota selecionada: $AMAZON_SELECTED_FILE"

if ((${#SITE_URLS[@]} > 0)); then
  for site in "${SITE_URLS[@]}"; do
    http_health "$site"
  done
else
  log "site: URL pública não identificada; seguindo com diagnóstico do servidor"
fi

build_ssh_args
remote_preflight "$destination"
log "abrindo sessão SSH interativa..."
exec ssh "${SSH_ARGS[@]}" "$destination"
