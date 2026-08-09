#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SERVICES_FILE="${SERVICES_FILE:-$PROJECT_ROOT/config/services.csv}"
STATIC_LOCATIONS_FILE="${STATIC_LOCATIONS_FILE:-$PROJECT_ROOT/config/static-locations.csv}"
MANAGED_NAME="${MANAGED_NAME:-dev-automation-local}"
NGINX_AVAILABLE_DIR="${NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
NGINX_ENABLED_DIR="${NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
MANAGED_FILE="$NGINX_AVAILABLE_DIR/$MANAGED_NAME.conf"
MANAGED_LINK="$NGINX_ENABLED_DIR/$MANAGED_NAME.conf"
TLS_DIR="${TLS_DIR:-/etc/nginx/$MANAGED_NAME-tls}"
TLS_CERT_FILE="$TLS_DIR/cert.pem"
TLS_KEY_FILE="$TLS_DIR/key.pem"
TLS_HOSTS_FILE="$TLS_DIR/hosts.txt"
NGINX_BIN="${NGINX_BIN:-nginx}"
MKCERT_BIN="${MKCERT_BIN:-mkcert}"

log() { printf '[local-nginx] %s\n' "$*"; }
fail() { printf '[local-nginx] ERRO: %s\n' "$*" >&2; exit 1; }

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

validate_services() {
  [[ -f "$SERVICES_FILE" ]] || fail "arquivo não encontrado: $SERVICES_FILE"

  local line_number=0
  local application type web_port api_port host path extra
  local -A applications=() web_ports=() api_ports=() routes=()
  local services=0

  while IFS=';' read -r application type web_port api_port host path extra || [[ -n "${application:-}${type:-}${web_port:-}${api_port:-}${host:-}${path:-}${extra:-}" ]]; do
    ((line_number += 1))

    application="$(trim "${application:-}")"
    type="$(trim "${type:-}")"
    web_port="$(trim "${web_port:-}")"
    api_port="$(trim "${api_port:-}")"
    host="$(trim "${host:-}")"
    path="$(trim "${path:-}")"
    extra="$(trim "${extra:-}")"

    if ((line_number == 1)); then
      [[ "$application;$type;$web_port;$api_port;$host;$path" == 'application;type;web_port;api_port;host;path' && -z "$extra" ]] ||
        fail "cabeçalho inválido em $SERVICES_FILE"
      continue
    fi

    [[ -n "$application" && -n "$type" && -n "$web_port" && -n "$api_port" && -n "$host" && -n "$path" ]] ||
      fail "linha $line_number tem campo obrigatório vazio"
    [[ -z "$extra" ]] || fail "linha $line_number tem campos extras"
    [[ "$type" == 'base' || "$type" == 'module' ]] || fail "linha $line_number tem tipo inválido: $type"
    [[ "$web_port" =~ ^[0-9]+$ ]] || fail "linha $line_number tem porta Web inválida: $web_port"
    [[ "$api_port" =~ ^[0-9]+$ ]] || fail "linha $line_number tem porta API inválida: $api_port"
    ((web_port >= 1 && web_port <= 65535)) || fail "linha $line_number tem porta Web fora da faixa: $web_port"
    ((api_port >= 1 && api_port <= 65535)) || fail "linha $line_number tem porta API fora da faixa: $api_port"
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || fail "linha $line_number tem host inválido: $host"
    [[ "$path" == /* ]] || fail "linha $line_number tem path inválido: $path"
    [[ "$path" == '/' || "$path" != */ ]] || fail "linha $line_number não deve terminar path com /: $path"

    local signature="$type|$web_port|$api_port"
    if [[ -n "${applications[$application]+x}" ]]; then
      [[ "${applications[$application]}" == "$signature" ]] ||
        fail "aplicação $application repetida com tipo ou portas diferentes"
    else
      [[ -z "${web_ports[$web_port]+x}" ]] ||
        fail "porta Web duplicada: $web_port (${web_ports[$web_port]} e $application)"
      [[ -z "${api_ports[$api_port]+x}" ]] ||
        fail "porta API duplicada: $api_port (${api_ports[$api_port]} e $application)"
      applications[$application]="$signature"
      web_ports[$web_port]="$application"
      api_ports[$api_port]="$application"
    fi

    local route_key="$host|$path"
    [[ -z "${routes[$route_key]+x}" ]] || fail "path duplicado no host $host: $path (${routes[$route_key]} e $application)"

    if [[ "$type" == 'module' && "$path" == '/' ]]; then
      fail "linha $line_number: módulo não pode usar path /"
    fi

    routes[$route_key]="$application"
    ((services += 1))
  done < "$SERVICES_FILE"

  ((services > 0)) || fail "nenhum serviço cadastrado"
  [[ "${routes['admin.localhost|/']:-}" == 'orbital-app' ]] || fail "admin.localhost / deve pertencer ao orbital-app"
}

validate_static_locations() {
  [[ -f "$STATIC_LOCATIONS_FILE" ]] || fail "arquivo não encontrado: $STATIC_LOCATIONS_FILE"

  local application type web_port api_port host path extra
  local -A applications=() routes=()
  while IFS=';' read -r application type web_port api_port host path extra; do
    [[ "$application" == 'application' ]] && continue
    application="$(trim "$application")"
    [[ -n "$application" ]] && applications[$application]=1
  done < "$SERVICES_FILE"

  local line_number=0 public_path physical_path
  local locations=0
  while IFS=';' read -r application public_path physical_path extra || [[ -n "${application:-}${public_path:-}${physical_path:-}${extra:-}" ]]; do
    ((line_number += 1))

    application="$(trim "${application:-}")"
    public_path="$(trim "${public_path:-}")"
    physical_path="$(trim "${physical_path:-}")"
    extra="$(trim "${extra:-}")"

    if ((line_number == 1)); then
      [[ "$application;$public_path;$physical_path" == 'application;public_path;physical_path' && -z "$extra" ]] ||
        fail "cabeçalho inválido em $STATIC_LOCATIONS_FILE"
      continue
    fi

    [[ -n "$application" && -n "$public_path" && -n "$physical_path" ]] ||
      fail "linha $line_number de $STATIC_LOCATIONS_FILE tem campo obrigatório vazio"
    [[ -z "$extra" ]] || fail "linha $line_number de $STATIC_LOCATIONS_FILE tem campos extras"
    [[ -n "${applications[$application]+x}" ]] ||
      fail "linha $line_number referencia aplicação desconhecida: $application"
    [[ "$public_path" == /*/ ]] ||
      fail "linha $line_number tem caminho público inválido: $public_path"
    [[ "$physical_path" == /*/ ]] ||
      fail "linha $line_number tem caminho físico inválido: $physical_path"

    local route_key="$application|$public_path"
    [[ -z "${routes[$route_key]+x}" ]] ||
      fail "rota estática duplicada para $application: $public_path"
    routes[$route_key]=1
    ((locations += 1))
  done < "$STATIC_LOCATIONS_FILE"

  ((locations > 0)) || fail "nenhuma rota estática cadastrada"
}

collect_hosts() {
  validate_services
  awk -F';' 'NR > 1 && !seen[$5]++ {print $5}' "$SERVICES_FILE"
}

emit_proxy_headers() {
  cat <<'EOF_HEADERS'
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
EOF_HEADERS
}

emit_static_locations_for_host() {
  local target_host="$1"
  local application type web_port api_port host path extra
  local -A host_applications=()

  while IFS=';' read -r application type web_port api_port host path extra; do
    [[ "$application" == 'application' ]] && continue
    application="$(trim "$application")"
    host="$(trim "$host")"
    [[ "$host" == "$target_host" ]] && host_applications[$application]=1
  done < "$SERVICES_FILE"

  local public_path physical_path
  while IFS=';' read -r application public_path physical_path extra; do
    [[ "$application" == 'application' ]] && continue
    application="$(trim "$application")"
    public_path="$(trim "$public_path")"
    physical_path="$(trim "$physical_path")"
    [[ -n "${host_applications[$application]+x}" ]] || continue

    cat <<EOF_STATIC
    location ^~ $public_path {
        alias $physical_path;
    }

EOF_STATIC
  done < "$STATIC_LOCATIONS_FILE"
}

generate_config() {
  validate_services
  validate_static_locations

  local host application type web_port api_port row_host path extra
  local -a hosts=()
  mapfile -t hosts < <(collect_hosts)

  for host in "${hosts[@]}"; do
    cat <<EOF_REDIRECT
# generated-by: dev-automation/local-nginx.sh
server {
    listen 80;
    listen [::]:80;
    server_name $host;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $host;

    ssl_certificate $TLS_CERT_FILE;
    ssl_certificate_key $TLS_KEY_FILE;

EOF_REDIRECT

    while IFS=';' read -r application type web_port api_port row_host path extra; do
      [[ "$application" == 'application' ]] && continue

      web_port="$(trim "$web_port")"
      api_port="$(trim "$api_port")"
      row_host="$(trim "$row_host")"
      path="$(trim "$path")"
      [[ "$row_host" == "$host" ]] || continue

      if [[ "$path" == '/' ]]; then
        cat <<EOF_LOCATION
    location = /api {
        return 308 /api/;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:$api_port/;
$(emit_proxy_headers)
    }

    location / {
        proxy_pass http://127.0.0.1:$web_port;
$(emit_proxy_headers)
    }

EOF_LOCATION
        continue
      fi

      cat <<EOF_LOCATION
    location $path/api/ {
        proxy_pass http://127.0.0.1:$api_port/api/;
$(emit_proxy_headers)
    }

    location $path/ {
        proxy_pass http://127.0.0.1:$web_port;
$(emit_proxy_headers)
    }

EOF_LOCATION
    done < "$SERVICES_FILE"

    emit_static_locations_for_host "$host"

    printf '}\n\n'
  done
}

as_root() {
  if ((EUID == 0)); then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || fail "sudo não encontrado"
    sudo "$@"
  fi
}

ensure_nginx() {
  command -v "$NGINX_BIN" >/dev/null 2>&1 && return
  command -v apt-get >/dev/null 2>&1 || fail "nginx ausente e apt-get não está disponível"
  log 'instalando nginx'
  as_root apt-get update
  as_root apt-get install -y nginx
  command -v "$NGINX_BIN" >/dev/null 2>&1 || fail "nginx não foi instalado"
}

ensure_mkcert() {
  command -v "$MKCERT_BIN" >/dev/null 2>&1 && return
  command -v apt-get >/dev/null 2>&1 || fail "mkcert ausente e apt-get não está disponível"
  log 'instalando mkcert'
  as_root apt-get update
  as_root apt-get install -y mkcert libnss3-tools ca-certificates
  command -v "$MKCERT_BIN" >/dev/null 2>&1 || fail "mkcert não foi instalado"
}

is_wsl() {
  [[ -n "${WSL_INTEROP:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null
}

trust_local_ca() {
  "$MKCERT_BIN" -install >/dev/null

  if is_wsl; then
    command -v certutil.exe >/dev/null 2>&1 || fail "WSL detectado, mas certutil.exe não está disponível para confiar a CA no Windows"
    command -v wslpath >/dev/null 2>&1 || fail "WSL detectado, mas wslpath não está disponível"

    local ca_root ca_file windows_ca_file
    ca_root="$("$MKCERT_BIN" -CAROOT)"
    ca_file="$ca_root/rootCA.pem"
    [[ -f "$ca_file" ]] || fail "CA do mkcert não encontrada: $ca_file"
    windows_ca_file="$(wslpath -w "$ca_file")"
    certutil.exe -user -addstore Root "$windows_ca_file" >/dev/null 2>&1 ||
      fail "não foi possível confiar a CA local no Windows"
  fi
}

ensure_tls_certificate() {
  ensure_mkcert
  trust_local_ca

  local desired_hosts temp_dir temp_cert temp_key regenerate=0
  desired_hosts="$(collect_hosts)"

  if [[ ! -f "$TLS_CERT_FILE" || ! -f "$TLS_KEY_FILE" || ! -f "$TLS_HOSTS_FILE" ]]; then
    regenerate=1
  elif [[ "$(cat "$TLS_HOSTS_FILE")" != "$desired_hosts" ]]; then
    regenerate=1
  elif command -v openssl >/dev/null 2>&1 && ! openssl x509 -checkend 604800 -noout -in "$TLS_CERT_FILE" >/dev/null 2>&1; then
    regenerate=1
  fi

  ((regenerate)) || return

  temp_dir="$(mktemp -d /tmp/dev-automation-tls-XXXXXX)"
  temp_cert="$temp_dir/cert.pem"
  temp_key="$temp_dir/key.pem"
  trap 'rm -rf -- "${temp_dir:-}"' RETURN

  local -a hosts=()
  mapfile -t hosts <<< "$desired_hosts"
  "$MKCERT_BIN" -cert-file "$temp_cert" -key-file "$temp_key" "${hosts[@]}" >/dev/null
  [[ -s "$temp_cert" && -s "$temp_key" ]] || fail "mkcert não gerou certificado/chave"

  as_root mkdir -p "$TLS_DIR"
  as_root install -m 0644 "$temp_cert" "$TLS_CERT_FILE"
  as_root install -m 0600 "$temp_key" "$TLS_KEY_FILE"
  printf '%s\n' "$desired_hosts" > "$temp_dir/hosts.txt"
  as_root install -m 0644 "$temp_dir/hosts.txt" "$TLS_HOSTS_FILE"
  log "certificado HTTPS local atualizado para ${#hosts[@]} host(s)"
}

validate_candidate_with_nginx() {
  local candidate="$1"
  local temp_dir temp_main

  command -v "$NGINX_BIN" >/dev/null 2>&1 || return 0

  temp_dir="$(mktemp -d /tmp/dev-automation-nginx-XXXXXX)"
  temp_main="$temp_dir/nginx.conf"
  trap 'rm -rf -- "${temp_dir:-}"' RETURN

  cat > "$temp_main" <<EOF_MAIN
pid $temp_dir/nginx.pid;
events {}
http {
    access_log off;
    include /etc/nginx/mime.types;
    include $candidate;
}
EOF_MAIN

  if ! as_root "$NGINX_BIN" -t -c "$temp_main" -g "error_log stderr;"; then
    fail 'nginx -t rejeitou a configuração gerada'
  fi
}

activate_nginx() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet nginx 2>/dev/null; then
      as_root systemctl reload nginx
    else
      as_root systemctl start nginx
    fi
    return
  fi

  if command -v service >/dev/null 2>&1; then
    if service nginx status >/dev/null 2>&1; then
      as_root service nginx reload
    else
      as_root service nginx start
    fi
    return
  fi

  "$NGINX_BIN" -s reload 2>/dev/null || as_root "$NGINX_BIN"
}

install_config() {
  ensure_nginx
  validate_services
  validate_static_locations
  ensure_tls_certificate

  local temp_file backup_file had_previous=0
  temp_file="$(mktemp /tmp/$MANAGED_NAME.conf.XXXXXX)"
  backup_file="$(mktemp /tmp/$MANAGED_NAME.backup.XXXXXX)"
  trap 'rm -f -- "${temp_file:-}" "${backup_file:-}"' EXIT

  generate_config > "$temp_file"
  validate_candidate_with_nginx "$temp_file"

  if [[ -f "$MANAGED_FILE" ]] && cmp -s "$temp_file" "$MANAGED_FILE" && [[ -L "$MANAGED_LINK" ]] && [[ "$(readlink -f "$MANAGED_LINK")" == "$(readlink -f "$MANAGED_FILE")" ]]; then
    log 'configuração já está atualizada'
    activate_nginx
    return
  fi

  as_root mkdir -p "$NGINX_AVAILABLE_DIR" "$NGINX_ENABLED_DIR"

  if [[ -f "$MANAGED_FILE" ]]; then
    as_root cp -a "$MANAGED_FILE" "$backup_file"
    had_previous=1
  fi

  as_root install -m 0644 "$temp_file" "$MANAGED_FILE"
  as_root ln -sfn "$MANAGED_FILE" "$MANAGED_LINK"

  if ! as_root "$NGINX_BIN" -t; then
    if ((had_previous)); then
      as_root cp -a "$backup_file" "$MANAGED_FILE"
    else
      as_root rm -f "$MANAGED_FILE"
    fi
    as_root rm -f "$MANAGED_LINK"
    ((had_previous)) && as_root ln -s "$MANAGED_FILE" "$MANAGED_LINK"
    fail 'nginx -t falhou; configuração anterior restaurada'
  fi

  activate_nginx
  log "gateways HTTPS locais atualizados a partir de $SERVICES_FILE"
}

case "${1:-}" in
  --render)
    generate_config
    ;;
  --validate)
    validate_services
    validate_static_locations
    log 'services.csv e static-locations.csv válidos'
    ;;
  ''|--install)
    install_config
    ;;
  *)
    fail "uso: $(basename "$0") [--install|--validate|--render]"
    ;;
esac
