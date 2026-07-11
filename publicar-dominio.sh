#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$DEPLOY_DIR/publicar-dominio.conf"
MODE="check"

usage() {
  cat <<USAGE
Uso:
  ./publicar-dominio.sh [--check] [arquivo.conf]
  ./publicar-dominio.sh --apply [arquivo.conf]

Sem opção ou com --check:
  sincroniza o espelho local do Nginx, gera o arquivo local e mostra o diff,
  mas não altera o servidor.

Com --apply:
  executa o mesmo fluxo e, após confirmação, publica somente este domínio.
USAGE
}

case "${1:-}" in
  --check) MODE="check"; shift ;;
  --apply) MODE="apply"; shift ;;
  -h|--help) usage; exit 0 ;;
  "") ;;
  *)
    if [[ "${1:-}" == *.conf ]]; then
      CONFIG_FILE="$1"
      shift
    else
      echo "ERRO: opção inválida: $1" >&2
      usage
      exit 1
    fi
    ;;
esac

if [[ $# -gt 0 ]]; then
  CONFIG_FILE="$1"
  shift
fi
[[ $# -eq 0 ]] || { echo "ERRO: argumentos excedentes." >&2; usage; exit 1; }

[[ -f "$CONFIG_FILE" ]] || { echo "ERRO: configuração não encontrada: $CONFIG_FILE" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONFIG_FILE"

log()  { printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[AVISO] %s\n' "$*" >&2; }
die()  { printf '[ERRO] %s\n' "$*" >&2; exit 1; }

: "${REMOTE_USER:?Defina REMOTE_USER}"
: "${REMOTE_HOST:?Defina REMOTE_HOST}"
: "${SSH_KEY:?Defina SSH_KEY}"
: "${SITE_NAME:?Defina SITE_NAME}"
: "${APP_NAME:?Defina APP_NAME}"
: "${UPSTREAM_HOST:?Defina UPSTREAM_HOST}"
: "${UPSTREAM_PORT:?Defina UPSTREAM_PORT}"
: "${SSL_EMAIL:?Defina SSL_EMAIL}"
: "${LOCAL_SERVER_DIR:?Defina LOCAL_SERVER_DIR}"

[[ -f "$SSH_KEY" ]] || die "Chave SSH não encontrada: $SSH_KEY"
[[ ${#DOMAINS[@]} -gt 0 ]] || die "Informe ao menos um domínio em DOMAINS"
[[ "$UPSTREAM_PORT" =~ ^[0-9]+$ ]] || die "UPSTREAM_PORT deve ser numérica"
[[ "$SITE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "SITE_NAME contém caracteres inválidos"
[[ "$APP_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "APP_NAME contém caracteres inválidos"
command -v rsync >/dev/null || die "rsync não encontrado no WSL"
command -v ssh >/dev/null || die "ssh não encontrado no WSL"
command -v scp >/dev/null || die "scp não encontrado no WSL"

PRIMARY_DOMAIN="${DOMAINS[0]}"
CERT_NAME="$PRIMARY_DOMAIN"
DOMAIN_LIST="${DOMAINS[*]}"
REMOTE_AVAILABLE="/etc/nginx/sites-available"
REMOTE_ENABLED="/etc/nginx/sites-enabled"
LOCAL_SERVER_PATH="$(cd "$DEPLOY_DIR" && realpath -m "$LOCAL_SERVER_DIR")"
LOCAL_NGINX_DIR="$LOCAL_SERVER_PATH/etc/nginx"
LOCAL_AVAILABLE="$LOCAL_NGINX_DIR/sites-available"
LOCAL_FILE="$LOCAL_AVAILABLE/$SITE_NAME"
TMP_DIR="$(mktemp -d)"
PREVIOUS_LOCAL_FILE="$TMP_DIR/$SITE_NAME.before"
GENERATED_FILE="$TMP_DIR/$SITE_NAME.generated"
REMOTE_TMP="/tmp/${SITE_NAME}.deploy.$$"
REMOTE_BACKUP_DIR="/tmp/${SITE_NAME}.backup.$$"
LOCK_FILE="/tmp/publicar-dominio.lock"
CHANGED_REMOTE="false"
LOCK_ACQUIRED="false"

SSH_OPTS=(
  -i "$SSH_KEY"
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=6
  -o TCPKeepAlive=yes
)

remote() {
  ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" "$@"
}

cleanup() {
  rm -rf "$TMP_DIR"
  remote "rm -f '$REMOTE_TMP'; sudo rm -rf '$REMOTE_BACKUP_DIR'" >/dev/null 2>&1 || true
  if [[ "$LOCK_ACQUIRED" == "true" ]]; then
    remote "sudo rm -f '$LOCK_FILE'" >/dev/null 2>&1 || true
  fi
}

rollback() {
  local status=$?
  if [[ $status -ne 0 && "$MODE" == "apply" && "$CHANGED_REMOTE" == "true" ]]; then
    warn "Falha detectada. Restaurando somente a configuração de $SITE_NAME..."
    remote "
      set -e
      sudo rm -f '$REMOTE_AVAILABLE/$SITE_NAME' '$REMOTE_ENABLED/$SITE_NAME'
      if sudo test -e '$REMOTE_BACKUP_DIR/available'; then
        sudo cp -a '$REMOTE_BACKUP_DIR/available' '$REMOTE_AVAILABLE/$SITE_NAME'
      fi
      if sudo test -e '$REMOTE_BACKUP_DIR/enabled' || sudo test -L '$REMOTE_BACKUP_DIR/enabled'; then
        sudo cp -a '$REMOTE_BACKUP_DIR/enabled' '$REMOTE_ENABLED/$SITE_NAME'
      fi
      sudo nginx -t
      sudo systemctl reload nginx
    " || warn "Rollback automático falhou; verifique o Nginx imediatamente."
  fi
  cleanup
  exit "$status"
}
trap rollback EXIT

validate_domain() {
  local domain="$1"
  [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || die "Domínio inválido: $domain"
}
for domain in "${DOMAINS[@]}"; do validate_domain "$domain"; done

sync_nginx_from_server() {
  mkdir -p "$LOCAL_NGINX_DIR"

  # sites-enabled e modules-enabled são links/estado de ativação do servidor.
  # Eles são exibidos, mas não são espelhados para evitar links inválidos no WSL.
  rsync -avz --delete \
    --no-owner \
    --no-group \
    --exclude 'sites-enabled/' \
    --exclude 'modules-enabled/' \
    -e "ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -o TCPKeepAlive=yes" \
    --rsync-path="sudo rsync" \
    "$REMOTE_USER@$REMOTE_HOST:/etc/nginx/" \
    "$LOCAL_NGINX_DIR/"
}

show_remote_inventory() {
  remote "
    set -e
    echo
    echo 'SITES DISPONÍVEIS (/etc/nginx/sites-available)'
    echo '------------------------------------------------------------'
    sudo find '$REMOTE_AVAILABLE' -maxdepth 1 -mindepth 1 -printf '%f\n' | sort

    echo
    echo 'SITES HABILITADOS (/etc/nginx/sites-enabled)'
    echo '------------------------------------------------------------'
    for item in '$REMOTE_ENABLED'/*; do
      [ -e \"\$item\" ] || [ -L \"\$item\" ] || continue
      printf '%-38s -> %s\n' \"\$(basename \"\$item\")\" \"\$(readlink -f \"\$item\" 2>/dev/null || echo ARQUIVO)\"
    done | sort
  "
}

render_config() {
  if [[ "${ISSUE_SSL:-true}" == "true" ]] && remote "sudo test -s '/etc/letsencrypt/live/$CERT_NAME/fullchain.pem' && sudo test -s '/etc/letsencrypt/live/$CERT_NAME/privkey.pem'"; then
    cat > "$GENERATED_FILE" <<NGINX
server {
    listen 80;
    listen [::]:80;

    server_name $DOMAIN_LIST;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name $DOMAIN_LIST;

    ssl_certificate /etc/letsencrypt/live/$CERT_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$CERT_NAME/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    add_header X-Site-App "$APP_NAME" always;
    client_max_body_size ${CLIENT_MAX_BODY_SIZE:-20m};

    location / {
        proxy_pass http://$UPSTREAM_HOST:$UPSTREAM_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout ${PROXY_READ_TIMEOUT:-60s};
    }
}
NGINX
  else
    cat > "$GENERATED_FILE" <<NGINX
server {
    listen 80;
    listen [::]:80;

    server_name $DOMAIN_LIST;

    add_header X-Site-App "$APP_NAME" always;
    client_max_body_size ${CLIENT_MAX_BODY_SIZE:-20m};

    location / {
        proxy_pass http://$UPSTREAM_HOST:$UPSTREAM_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout ${PROXY_READ_TIMEOUT:-60s};
    }
}
NGINX
  fi
}

install_local_generated_file() {
  mkdir -p "$LOCAL_AVAILABLE"
  if [[ -f "$LOCAL_FILE" ]]; then
    cp -a "$LOCAL_FILE" "$PREVIOUS_LOCAL_FILE"
  else
    : > "$PREVIOUS_LOCAL_FILE"
  fi
  install -m 0644 "$GENERATED_FILE" "$LOCAL_FILE"
}

show_diff() {
  echo
  echo "ARQUIVO LOCAL GERADO"
  echo "------------------------------------------------------------"
  echo "$LOCAL_FILE"
  echo
  echo "ALTERAÇÕES PROPOSTAS"
  echo "------------------------------------------------------------"
  if diff -u "$PREVIOUS_LOCAL_FILE" "$LOCAL_FILE"; then
    echo "(sem alterações; arquivo já está no padrão desejado)"
  fi
}

push_local_site() {
  scp "${SSH_OPTS[@]}" "$LOCAL_FILE" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_TMP" >/dev/null
  CHANGED_REMOTE="true"
  remote "
    set -e
    sudo install -m 0644 '$REMOTE_TMP' '$REMOTE_AVAILABLE/$SITE_NAME'
    sudo ln -sfn '$REMOTE_AVAILABLE/$SITE_NAME' '$REMOTE_ENABLED/$SITE_NAME'
    sudo nginx -t
    sudo systemctl reload nginx
  "
}

verify_site_identity() {
  local expected="$APP_NAME"
  local received

  if [[ "${ISSUE_SSL:-true}" == "true" ]]; then
    received="$(remote "curl -skI --max-time 20 --resolve '$PRIMARY_DOMAIN:443:127.0.0.1' 'https://$PRIMARY_DOMAIN/' | tr -d '\r' | awk -F': ' 'tolower(\$1) == \"x-site-app\" {print \$2; exit}'")"
  else
    received="$(remote "curl -sI --max-time 20 -H 'Host: $PRIMARY_DOMAIN' 'http://127.0.0.1/' | tr -d '\r' | awk -F': ' 'tolower(\$1) == \"x-site-app\" {print \$2; exit}'")"
  fi

  [[ "$received" == "$expected" ]] || die "O domínio respondeu pelo site errado. Esperado X-Site-App=$expected; recebido=${received:-ausente}"
  ok "Identidade confirmada: X-Site-App=$received"
}

log "Publicação segura de $SITE_NAME"
echo "Modo          : $MODE"
echo "Servidor      : $REMOTE_USER@$REMOTE_HOST"
echo "Espelho local : $LOCAL_NGINX_DIR"
echo "Domínios      : $DOMAIN_LIST"
echo "Aplicativo    : $APP_NAME"
echo "Upstream      : http://$UPSTREAM_HOST:$UPSTREAM_PORT"
echo "SSL           : ${ISSUE_SSL:-true}"

log "Validando conexão, ferramentas e estado atual"
remote "true"
ok "SSH conectado"
remote "command -v nginx >/dev/null && command -v curl >/dev/null && command -v systemctl >/dev/null && command -v rsync >/dev/null" || die "Nginx, curl, systemctl ou rsync não encontrado no servidor"
if [[ "${ISSUE_SSL:-true}" == "true" ]]; then
  remote "command -v certbot >/dev/null" || die "Certbot não encontrado"
fi
remote "sudo nginx -t"
remote "systemctl is-active --quiet nginx"
ok "Nginx atual está válido e ativo"

log "Sincronizando /etc/nginx do servidor para o espelho local"
sync_nginx_from_server
ok "Espelho local atualizado antes de gerar qualquer arquivo"

log "Inventário atual do Nginx no servidor"
show_remote_inventory

log "Verificando a aplicação antes de preparar o domínio"
remote "curl --silent --show-error --fail --max-time 15 'http://$UPSTREAM_HOST:$UPSTREAM_PORT/' >/dev/null" || die "Aplicação não respondeu em http://$UPSTREAM_HOST:$UPSTREAM_PORT"
ok "Aplicação respondeu"

log "Verificando conflito de domínios em outros sites habilitados"
for domain in "${DOMAINS[@]}"; do
  conflicts="$(remote "sudo grep -RIl --include='*' -E 'server_name[[:space:]][^;]*([^A-Za-z0-9.-]|^)$domain([^A-Za-z0-9.-]|$)' '$REMOTE_ENABLED' 2>/dev/null || true")"
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    [[ "$file" == "$REMOTE_ENABLED/$SITE_NAME" ]] && continue
    die "O domínio $domain já aparece em outro site habilitado: $file"
  done <<< "$conflicts"
done
ok "Nenhum conflito de server_name encontrado"

log "Verificando DNS"
for domain in "${DOMAINS[@]}"; do
  resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, - || true)"
  if [[ -z "$resolved" ]]; then
    warn "$domain ainda não resolve em DNS"
  elif [[ ",$resolved," == *",$REMOTE_HOST,"* ]]; then
    ok "$domain resolve diretamente para $REMOTE_HOST"
  else
    warn "$domain resolve para $resolved; pode ser proxy do Cloudflare"
  fi
done

log "Gerando a configuração no espelho local"
render_config
install_local_generated_file
show_diff

if [[ "$MODE" == "check" ]]; then
  log "Verificação concluída"
  echo "O espelho local foi sincronizado e o arquivo foi gerado localmente."
  echo "Nenhuma alteração foi feita no servidor."
  echo
  echo "Para publicar exatamente este arquivo:"
  echo "  ./publicar-dominio.sh --apply"
  trap - EXIT
  cleanup
  exit 0
fi

echo
read -r -p "Publicar somente $SITE_NAME em $REMOTE_HOST? Digite PUBLICAR para continuar: " confirmation
[[ "$confirmation" == "PUBLICAR" ]] || die "Publicação cancelada pelo usuário"

log "Obtendo trava exclusiva de publicação"
remote "sudo sh -c 'set -C; : > \"$LOCK_FILE\"'" 2>/dev/null || die "Outra publicação parece estar em andamento: $LOCK_FILE"
LOCK_ACQUIRED="true"
ok "Trava obtida"

log "Criando backup exato do arquivo e do link deste site"
remote "
  set -e
  sudo mkdir -p '$REMOTE_BACKUP_DIR'
  if sudo test -e '$REMOTE_AVAILABLE/$SITE_NAME'; then
    sudo cp -a '$REMOTE_AVAILABLE/$SITE_NAME' '$REMOTE_BACKUP_DIR/available'
  fi
  if sudo test -e '$REMOTE_ENABLED/$SITE_NAME' || sudo test -L '$REMOTE_ENABLED/$SITE_NAME'; then
    sudo cp -a '$REMOTE_ENABLED/$SITE_NAME' '$REMOTE_BACKUP_DIR/enabled'
  fi
"
ok "Backup temporário criado"

log "Enviando somente o arquivo local deste domínio"
push_local_site
ok "Arquivo publicado, habilitado e Nginx recarregado"

if [[ "${ISSUE_SSL:-true}" == "true" ]]; then
  if ! remote "sudo test -s '/etc/letsencrypt/live/$CERT_NAME/fullchain.pem' && sudo test -s '/etc/letsencrypt/live/$CERT_NAME/privkey.pem'"; then
    log "Emitindo certificado Let's Encrypt"
    CERTBOT_ARGS=()
    for domain in "${DOMAINS[@]}"; do CERTBOT_ARGS+=("-d" "$domain"); done
    printf -v CERTBOT_CMD ' %q' sudo certbot certonly --nginx --non-interactive --agree-tos --no-eff-email --keep-until-expiring --cert-name "$CERT_NAME" -m "$SSL_EMAIL" "${CERTBOT_ARGS[@]}"
    remote "$CERTBOT_CMD"
    remote "sudo test -s '/etc/letsencrypt/live/$CERT_NAME/fullchain.pem' && sudo test -s '/etc/letsencrypt/live/$CERT_NAME/privkey.pem'" || die "Certificado não encontrado após o Certbot"
    ok "Certificado emitido"

    log "Regenerando o arquivo local com HTTPS"
    render_config
    install -m 0644 "$GENERATED_FILE" "$LOCAL_FILE"

    log "Enviando a versão HTTPS definitiva"
    push_local_site
  else
    ok "Certificado existente reutilizado"
  fi
fi

log "Verificações finais"
remote "sudo nginx -t"
remote "systemctl is-active --quiet nginx"
remote "sudo test -L '$REMOTE_ENABLED/$SITE_NAME'"
remote "curl --silent --show-error --fail --max-time 15 'http://$UPSTREAM_HOST:$UPSTREAM_PORT/' >/dev/null"
verify_site_identity

log "Sincronizando novamente o estado final do servidor para o repositório"
sync_nginx_from_server
ok "Espelho local final atualizado a partir do servidor"

CHANGED_REMOTE="false"
trap - EXIT
cleanup

echo
ok "Domínio publicado com sucesso"
echo "URL: $([[ "${ISSUE_SSL:-true}" == "true" ]] && echo https || echo http)://$PRIMARY_DOMAIN"
