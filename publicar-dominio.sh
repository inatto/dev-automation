#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$DEPLOY_DIR/publicar-dominio.conf"
MODE="check"

usage() {
  cat <<USAGE
Uso:
  ./publicar-dominio.sh --check [arquivo.conf]
  ./publicar-dominio.sh --apply [arquivo.conf]

--check  Faz todas as validações sem alterar o servidor (padrão).
--apply  Publica de fato, com backup e rollback automático.
USAGE
}

case "${1:-}" in
  --check) MODE="check"; shift ;;
  --apply) MODE="apply"; shift ;;
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "ERRO: opção inválida: $1" >&2; usage; exit 1 ;;
esac

if [[ $# -gt 0 ]]; then
  CONFIG_FILE="$1"
fi

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
: "${UPSTREAM_HOST:?Defina UPSTREAM_HOST}"
: "${UPSTREAM_PORT:?Defina UPSTREAM_PORT}"
: "${SSL_EMAIL:?Defina SSL_EMAIL}"
: "${LOCAL_SERVER_DIR:?Defina LOCAL_SERVER_DIR}"

[[ -f "$SSH_KEY" ]] || die "Chave SSH não encontrada: $SSH_KEY"
[[ ${#DOMAINS[@]} -gt 0 ]] || die "Informe ao menos um domínio em DOMAINS"
[[ "$UPSTREAM_PORT" =~ ^[0-9]+$ ]] || die "UPSTREAM_PORT deve ser numérica"
[[ "$SITE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "SITE_NAME contém caracteres inválidos"

PRIMARY_DOMAIN="${DOMAINS[0]}"
CERT_NAME="$PRIMARY_DOMAIN"
DOMAIN_LIST="${DOMAINS[*]}"
REMOTE_AVAILABLE="/etc/nginx/sites-available"
REMOTE_ENABLED="/etc/nginx/sites-enabled"
LOCAL_AVAILABLE="$DEPLOY_DIR/$LOCAL_SERVER_DIR/etc/nginx/sites-available"
LOCAL_FILE="$LOCAL_AVAILABLE/$SITE_NAME"
TMP_DIR="$(mktemp -d)"
HTTP_FILE="$TMP_DIR/$SITE_NAME.http"
HTTPS_FILE="$TMP_DIR/$SITE_NAME.https"
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
      if sudo test -e '$REMOTE_BACKUP_DIR/enabled'; then
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

render_http() {
  cat > "$HTTP_FILE" <<NGINX
server {
    listen 80;
    listen [::]:80;

    server_name $DOMAIN_LIST;

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
}

render_https() {
  cat > "$HTTPS_FILE" <<NGINX
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
}

install_config() {
  local source_file="$1"
  scp "${SSH_OPTS[@]}" "$source_file" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_TMP" >/dev/null

  # Marca antes da primeira alteração para garantir rollback até em falha no nginx -t.
  CHANGED_REMOTE="true"

  remote "
    set -e
    sudo install -m 0644 '$REMOTE_TMP' '$REMOTE_AVAILABLE/$SITE_NAME'
    sudo ln -sfn '$REMOTE_AVAILABLE/$SITE_NAME' '$REMOTE_ENABLED/$SITE_NAME'
    sudo nginx -t
    sudo systemctl reload nginx
  "
}

log "Validação segura de $SITE_NAME"
echo "Modo     : $MODE"
echo "Servidor : $REMOTE_USER@$REMOTE_HOST"
echo "Domínios : $DOMAIN_LIST"
echo "Upstream : http://$UPSTREAM_HOST:$UPSTREAM_PORT"
echo "SSL      : ${ISSUE_SSL:-true}"

log "Validando conexão, ferramentas e estado atual"
remote "true"
ok "SSH conectado"
remote "command -v nginx >/dev/null && command -v curl >/dev/null && command -v systemctl >/dev/null" || die "Nginx, curl ou systemctl não encontrado"
if [[ "${ISSUE_SSL:-true}" == "true" ]]; then
  remote "command -v certbot >/dev/null" || die "Certbot não encontrado"
fi
remote "sudo nginx -t"
remote "systemctl is-active --quiet nginx"
ok "Nginx atual está válido e ativo"

log "Verificando a aplicação antes de tocar no Nginx"
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

render_http

if [[ "$MODE" == "check" ]]; then
  log "Pré-validação concluída; nenhuma alteração foi feita"
  echo "Para publicar:"
  echo "  ./publicar-dominio.sh --apply"
  trap - EXIT
  cleanup
  exit 0
fi

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
  sudo chown -R '$REMOTE_USER':'$REMOTE_USER' '$REMOTE_BACKUP_DIR'
"
ok "Backup temporário criado"

log "Instalando configuração HTTP inicial"
install_config "$HTTP_FILE"
ok "HTTP ativado sem alterar outros arquivos de site"

if [[ "${ISSUE_SSL:-true}" == "true" ]]; then
  log "Emitindo ou reutilizando certificado Let's Encrypt"
  CERTBOT_ARGS=()
  for domain in "${DOMAINS[@]}"; do CERTBOT_ARGS+=("-d" "$domain"); done
  printf -v CERTBOT_CMD ' %q' sudo certbot certonly --nginx --non-interactive --agree-tos --no-eff-email --keep-until-expiring --cert-name "$CERT_NAME" -m "$SSL_EMAIL" "${CERTBOT_ARGS[@]}"
  remote "$CERTBOT_CMD"
  remote "sudo test -s '/etc/letsencrypt/live/$CERT_NAME/fullchain.pem' && sudo test -s '/etc/letsencrypt/live/$CERT_NAME/privkey.pem'" || die "Certificado não encontrado após o Certbot"
  ok "Certificado disponível"

  render_https
  log "Instalando configuração HTTPS definitiva"
  install_config "$HTTPS_FILE"
  FINAL_FILE="$HTTPS_FILE"
else
  FINAL_FILE="$HTTP_FILE"
fi

log "Verificações finais"
remote "sudo nginx -t"
remote "systemctl is-active --quiet nginx"
remote "sudo test -L '$REMOTE_ENABLED/$SITE_NAME'"
remote "curl --silent --show-error --fail --max-time 15 'http://$UPSTREAM_HOST:$UPSTREAM_PORT/' >/dev/null"
if [[ "${ISSUE_SSL:-true}" == "true" ]]; then
  remote "curl --silent --show-error --fail --max-time 20 --resolve '$PRIMARY_DOMAIN:443:127.0.0.1' 'https://$PRIMARY_DOMAIN/' >/dev/null"
  ok "HTTPS respondeu localmente com certificado válido"
fi

log "Salvando espelho final no repositório"
mkdir -p "$LOCAL_AVAILABLE"
install -m 0644 "$FINAL_FILE" "$LOCAL_FILE"
ok "Salvo em $LOCAL_FILE"

CHANGED_REMOTE="false"
trap - EXIT
cleanup

echo
ok "Domínio publicado com sucesso"
echo "URL: $([[ "${ISSUE_SSL:-true}" == "true" ]] && echo https || echo http)://$PRIMARY_DOMAIN"
