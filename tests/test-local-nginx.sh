#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SCRIPT="$PROJECT_ROOT/scripts/local-nginx.sh"
SERVICES="$PROJECT_ROOT/config/services.csv"
STATIC_LOCATIONS="$PROJECT_ROOT/config/static-locations.csv"
TEMP_ROOT="$(mktemp -d /tmp/local-nginx-test-XXXXXX)"

cleanup() {
  rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FALHOU: %s\n' "$*" >&2
  exit 1
}

expect_fail() {
  local expected="$1"
  shift
  local output
  if output="$($@ 2>&1)"; then
    fail "comando deveria falhar: $*"
  fi
  grep -Fq "$expected" <<<"$output" || fail "erro esperado não encontrado: $expected; saída: $output"
}

"$SCRIPT" --validate >/dev/null
"$SCRIPT" test >/dev/null
config_one="$TEMP_ROOT/one.conf"
config_two="$TEMP_ROOT/two.conf"
"$SCRIPT" --render > "$config_one"
"$SCRIPT" --render > "$config_two"
cmp -s "$config_one" "$config_two" || fail 'render repetido não é idempotente'

# Cada host cadastrado deve gerar exatamente um gateway HTTP + HTTPS.
host_count="$(awk -F';' 'NR > 1 && !seen[$5]++ {count++} END {print count+0}' "$SERVICES")"
tenant_gateway_count=1
gateway_count=$((host_count + tenant_gateway_count))
while IFS= read -r host; do
  grep -Fq "server_name $host;" "$config_one" || fail "$host ausente"
done < <(awk -F';' 'NR > 1 && !seen[$5]++ {print $5}' "$SERVICES")
! grep -Fq 'server_name site-inst.localhost;' "$config_one" || fail 'alias tecnico site-inst.localhost permaneceu publico'
[[ "$(grep -c '^    listen 80;$' "$config_one")" -eq "$gateway_count" ]] || fail 'cada gateway deve escutar IPv4 na porta 80'
[[ "$(grep -c '^    listen \[::\]:80;$' "$config_one")" -eq "$gateway_count" ]] || fail 'cada gateway deve escutar IPv6 na porta 80'
[[ "$(grep -c '^    listen 443 ssl;$' "$config_one")" -eq "$gateway_count" ]] || fail 'cada gateway deve escutar HTTPS IPv4 na porta 443'
[[ "$(grep -c '^    listen \[::\]:443 ssl;$' "$config_one")" -eq "$gateway_count" ]] || fail 'cada gateway deve escutar HTTPS IPv6 na porta 443'
[[ "$(grep -c 'return 301 https://\$host\$request_uri;' "$config_one")" -eq "$gateway_count" ]] || fail 'cada gateway deve redirecionar HTTP para HTTPS'
[[ "$(grep -c '^    location = /api {$' "$config_one")" -eq "$gateway_count" ]] || fail 'cada app-base deve normalizar /api para /api/'
[[ "$(grep -c '^        return 308 /api/;$' "$config_one")" -eq "$gateway_count" ]] || fail 'cada app-base deve preservar o redirect /api do remoto'
[[ "$(grep -c '^    ssl_certificate ' "$config_one")" -eq "$gateway_count" ]] || fail 'cada gateway HTTPS deve usar certificado'
[[ "$(grep -c '^    location / {$' "$config_one")" -eq "$gateway_count" ]] || fail 'cada app-base deve ter exatamente um location /'

# Orbital é o foco do admin.localhost.
admin_block="$TEMP_ROOT/admin.conf"
awk '/server_name admin\.localhost;/{count++; if (count == 2) on=1} on{print} on && /^}$/{exit}' "$config_one" > "$admin_block"
grep -Fq 'proxy_pass http://127.0.0.1:4001;' "$admin_block" || fail 'admin / não usa Web orbital-app 4001'
grep -Fq 'proxy_pass http://127.0.0.1:8001/;' "$admin_block" || fail 'admin /api não usa API orbital-app 8001'
grep -Fq 'proxy_pass http://127.0.0.1:4106;' "$admin_block" || fail 'Web do mail não usa 4106'
grep -Fq 'proxy_pass http://127.0.0.1:8106/api/;' "$admin_block" || fail 'API do mail não usa 8106'
grep -Fq 'proxy_pass http://127.0.0.1:4108;' "$admin_block" || fail 'Web do reports não usa 4108'
grep -Fq 'proxy_pass http://127.0.0.1:8108/api/;' "$admin_block" || fail 'API do reports não usa 8108'
grep -Fq 'proxy_pass http://127.0.0.1:4111;' "$admin_block" || fail 'Web do legal não usa 4111'
grep -Fq 'proxy_pass http://127.0.0.1:8111/api/;' "$admin_block" || fail 'API do legal não usa 8111'
grep -Fq 'proxy_pass http://127.0.0.1:4115;' "$admin_block" || fail 'Web do benefit não usa 4115'
grep -Fq 'proxy_pass http://127.0.0.1:8115/api/;' "$admin_block" || fail 'API do benefit não usa 8115'
[[ "$(grep -c '^    location / {$' "$admin_block")" -eq 1 ]] || fail 'admin deve ter exatamente um location /'
awk '/location \/ \{/{getline; print; exit}' "$admin_block" | grep -Fq '127.0.0.1:4001' || fail 'admin / não pertence ao orbital-app'
! grep -Fq '4002' "$admin_block" || fail 'station-app vazou para admin.localhost'
! grep -Fq '4003' "$admin_block" || fail 'site-inst vazou para admin.localhost'
! grep -Fq 'proxy_set_header X-Tenant' "$admin_block" || fail 'admin.localhost canônico não deve forçar tenant'

# Qualquer <tenant>.admin.localhost replica o gateway admin sem cadastrar tenant.
tenant_admin_block="$TEMP_ROOT/tenant-admin.conf"
awk '/server_name ~\^\(\?<tenant>/{count++; if (count == 2) on=1} on{print} on && /^}$/{exit}' "$config_one" > "$tenant_admin_block"
grep -Fq 'server_name ~^(?<tenant>[A-Za-z0-9-]+)\.admin\.localhost$;' "$tenant_admin_block" || fail 'gateway dinâmico de tenant ausente'
grep -Fq 'proxy_pass http://127.0.0.1:4001;' "$tenant_admin_block" || fail 'tenant admin não usa Web orbital-app 4001'
grep -Fq 'proxy_pass http://127.0.0.1:8001/;' "$tenant_admin_block" || fail 'tenant admin não usa API orbital-app 8001'
grep -Fq 'proxy_pass http://127.0.0.1:4114;' "$tenant_admin_block" || fail 'tenant admin não replica orbital-tasks 4114'
grep -Fq 'proxy_pass http://127.0.0.1:8114/api/;' "$tenant_admin_block" || fail 'tenant admin não replica API orbital-tasks 8114'
grep -Fq 'proxy_pass http://127.0.0.1:4115;' "$tenant_admin_block" || fail 'tenant admin não replica orbital-benefit 4115'
grep -Fq 'proxy_pass http://127.0.0.1:8115/api/;' "$tenant_admin_block" || fail 'tenant admin não replica API orbital-benefit 8115'
grep -Fq 'proxy_set_header X-Tenant $tenant;' "$tenant_admin_block" || fail 'tenant capturado não é enviado em X-Tenant'
grep -Fq 'location ^~ /tenants/ {' "$tenant_admin_block" || fail 'tenant admin não replica publicação estática do admin'

module_count="$(awk -F';' 'NR > 1 && $2 == "module" {count++} END {print count+0}' "$SERVICES")"
generated_module_count="$(grep -Ec '^    location /orbital-[^/]+/ \{$' "$admin_block")"
[[ "$generated_module_count" -eq "$module_count" ]] || fail 'nem todos os módulos Orbital foram gerados automaticamente'

while IFS= read -r module_name; do
  grep -Fq "location /$module_name/ {" "$admin_block" || fail "módulo ausente: $module_name"
done < <(awk -F';' 'NR > 1 && $2 == "module" {print $1}' "$SERVICES")

# Demais apps-base usam host próprio; publicação estática é associada por aplicação.
painel_block="$TEMP_ROOT/painel.conf"
awk '/server_name painel\.localhost;/{count++; if (count == 2) on=1} on{print} on && /^}$/{exit}' "$config_one" > "$painel_block"
grep -Fq '127.0.0.1:4002' "$painel_block" || fail 'painel não usa station-app 4002'
grep -Fq '127.0.0.1:8002/' "$painel_block" || fail 'painel não usa API station-app 8002'
grep -Fq 'location ^~ /tenants/ {' "$painel_block" || fail 'painel não publica /tenants/'
grep -Fq 'alias /home/daniel/storage/tenants/;' "$painel_block" || fail 'painel usa storage de tenants incorreto'
! grep -Fq 'location ^~ /storage/' "$painel_block" || fail 'painel não deve criar rota /storage/'
for tenant in anpprev sinproprev; do
  site_block="$TEMP_ROOT/$tenant.conf"
  awk -v target="$tenant.localhost" '
    $0 ~ "server_name " target ";" {count++; if (count == 2) on=1}
    on {print}
    on && /^}$/ {exit}
  ' "$config_one" > "$site_block"
  grep -Fq '127.0.0.1:4003' "$site_block" || fail "$tenant não usa Web 4003"
  grep -Fq '127.0.0.1:8003/' "$site_block" || fail "$tenant não usa API 8003"
  grep -Fq 'location ^~ /tenants/ {' "$site_block" || fail "$tenant não publica /tenants/"
  grep -Fq 'alias /home/daniel/storage/tenants/;' "$site_block" || fail "$tenant usa storage de tenants incorreto"
  grep -Fq 'location ^~ /static/inst-app/ {' "$site_block" || fail "$tenant não publica /static/inst-app/"
  grep -Fq 'alias /home/daniel/storage/static/inst-app/;' "$site_block" || fail "$tenant usa storage estático incorreto"
done
grep -Fxq 'site-inst;/tenants/;/home/daniel/storage/tenants/' "$STATIC_LOCATIONS"
grep -Fxq 'station-app;/tenants/;/home/daniel/storage/tenants/' "$STATIC_LOCATIONS"
grep -Fxq 'site-inst;/static/inst-app/;/home/daniel/storage/static/inst-app/' "$STATIC_LOCATIONS"

# O gerador não conhece módulos ou apps individualmente.
if grep -Eq 'orbital-(assets|content|crm|events|fin|mail|marketing|reports|ui|vouchers|legal)|station-app|site-inst|conv-app|amazon-infra-monitor|monitor\.amazon\.infra|painel\.localhost' "$SCRIPT"; then
  fail 'há serviço ou módulo hardcoded no gerador'
fi

custom_csv="$TEMP_ROOT/custom.csv"
cp "$SERVICES" "$custom_csv"
printf 'orbital-new;module;4199;8199;admin.localhost;/orbital-new\n' >> "$custom_csv"
custom_config="$TEMP_ROOT/custom.conf"
SERVICES_FILE="$custom_csv" "$SCRIPT" --render > "$custom_config"
grep -Fq 'proxy_pass http://127.0.0.1:4199;' "$custom_config" || fail 'novo módulo do CSV não foi gerado'
grep -Fq 'proxy_pass http://127.0.0.1:8199/api/;' "$custom_config" || fail 'API de novo módulo do CSV não foi gerada'

custom_base_csv="$TEMP_ROOT/custom-base.csv"
cp "$SERVICES" "$custom_base_csv"
printf 'new-app;base;4990;8990;new-app.localhost;/\n' >> "$custom_base_csv"
custom_base_config="$TEMP_ROOT/custom-base.conf"
SERVICES_FILE="$custom_base_csv" "$SCRIPT" --render > "$custom_base_config"
grep -Fq 'server_name new-app.localhost;' "$custom_base_config" || fail 'novo host base do CSV não foi gerado'
grep -Fq 'proxy_pass http://127.0.0.1:4990;' "$custom_base_config" || fail 'novo app-base do CSV não foi gerado'

dup_web="$TEMP_ROOT/dup-web.csv"
cp "$SERVICES" "$dup_web"
printf 'x;module;4106;8991;admin.localhost;/x\n' >> "$dup_web"
expect_fail 'porta Web duplicada: 4106' env SERVICES_FILE="$dup_web" "$SCRIPT" --validate

dup_api="$TEMP_ROOT/dup-api.csv"
cp "$SERVICES" "$dup_api"
printf 'x;module;4991;8106;admin.localhost;/x\n' >> "$dup_api"
expect_fail 'porta API duplicada: 8106' env SERVICES_FILE="$dup_api" "$SCRIPT" --validate

dup_path="$TEMP_ROOT/dup-path.csv"
cp "$SERVICES" "$dup_path"
printf 'x;module;4991;8991;admin.localhost;/orbital-mail\n' >> "$dup_path"
expect_fail 'path duplicado no host admin.localhost: /orbital-mail' env SERVICES_FILE="$dup_path" "$SCRIPT" --validate

# O mesmo path / é válido em hosts diferentes.
same_path_other_host="$TEMP_ROOT/same-path-other-host.csv"
cp "$SERVICES" "$same_path_other_host"
printf 'x;base;4991;8991;x.localhost;/\n' >> "$same_path_other_host"
SERVICES_FILE="$same_path_other_host" "$SCRIPT" --validate >/dev/null

bad_port="$TEMP_ROOT/bad-port.csv"
cp "$SERVICES" "$bad_port"
printf 'x;module;abc;8991;admin.localhost;/x\n' >> "$bad_port"
expect_fail 'porta Web inválida: abc' env SERVICES_FILE="$bad_port" "$SCRIPT" --validate

empty_field="$TEMP_ROOT/empty-field.csv"
cp "$SERVICES" "$empty_field"
printf 'x;module;;8991;admin.localhost;/x\n' >> "$empty_field"
expect_fail 'campo obrigatório vazio' env SERVICES_FILE="$empty_field" "$SCRIPT" --validate

wrong_admin="$TEMP_ROOT/wrong-admin.csv"
awk -F';' 'BEGIN {OFS=";"} $1 == "orbital-app" {$5="orbital.localhost"} {print}' "$SERVICES" > "$wrong_admin"
expect_fail 'admin.localhost / deve pertencer ao orbital-app' env SERVICES_FILE="$wrong_admin" "$SCRIPT" --validate

fake_bin="$TEMP_ROOT/bin"
available="$TEMP_ROOT/sites-available"
enabled="$TEMP_ROOT/sites-enabled"
nginx_log="$TEMP_ROOT/nginx.log"
mkdir -p "$fake_bin" "$available" "$enabled"

cat > "$fake_bin/nginx" <<EOF_NGINX
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$nginx_log"
exit 0
EOF_NGINX
cat > "$fake_bin/mkcert" <<EOF_MKCERT
#!/usr/bin/env bash
if [[ "\${1:-}" == '-CAROOT' ]]; then
  printf '%s\n' '$TEMP_ROOT/fake-caroot'
  exit 0
fi
if [[ "\${1:-}" == '-install' ]]; then
  mkdir -p '$TEMP_ROOT/fake-caroot'
  printf 'fake-root-ca\n' > '$TEMP_ROOT/fake-caroot/rootCA.pem'
  exit 0
fi
cert=''
key=''
while ((\$#)); do
  case "\$1" in
    -cert-file) cert="\$2"; shift 2 ;;
    -key-file) key="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'fake-cert\n' > "\$cert"
printf 'fake-key\n' > "\$key"
EOF_MKCERT
cat > "$fake_bin/systemctl" <<'EOF_SYSTEMCTL'
#!/usr/bin/env bash
case "${1:-}" in
  is-active) exit 0 ;;
  reload|start) exit 0 ;;
esac
exit 0
EOF_SYSTEMCTL
cat > "$fake_bin/certutil.exe" <<'EOF_CERTUTIL'
#!/usr/bin/env bash
exit 0
EOF_CERTUTIL
cat > "$fake_bin/sudo" <<'EOF_SUDO'
#!/usr/bin/env bash
exec "$@"
EOF_SUDO
chmod +x "$fake_bin/nginx" "$fake_bin/mkcert" "$fake_bin/systemctl" "$fake_bin/certutil.exe" "$fake_bin/sudo"

PATH="$fake_bin:$PATH" \
NGINX_BIN=nginx \
NGINX_AVAILABLE_DIR="$available" \
NGINX_ENABLED_DIR="$enabled" \
TLS_DIR="$TEMP_ROOT/tls" \
  "$SCRIPT" --install >/dev/null

installed_one="$TEMP_ROOT/installed-one.conf"
cp "$available/dev-automation-local.conf" "$installed_one"

PATH="$fake_bin:$PATH" \
NGINX_BIN=nginx \
NGINX_AVAILABLE_DIR="$available" \
NGINX_ENABLED_DIR="$enabled" \
TLS_DIR="$TEMP_ROOT/tls" \
  "$SCRIPT" --install >/dev/null

cmp -s "$installed_one" "$available/dev-automation-local.conf" || fail 'instalação repetida alterou configuração'
[[ -L "$enabled/dev-automation-local.conf" ]] || fail 'symlink gerenciado não foi criado'
[[ -s "$TEMP_ROOT/tls/cert.pem" && -s "$TEMP_ROOT/tls/key.pem" ]] || fail 'certificado HTTPS local não foi gerado'
grep -Fxq '*.admin.localhost' "$TEMP_ROOT/tls/hosts.txt" || fail 'certificado não inclui wildcard *.admin.localhost'
grep -Eq '(^| )-t( |$)' "$nginx_log" || fail 'nginx -t não foi executado quando disponível'

rollback_available="$TEMP_ROOT/rollback-available"
rollback_enabled="$TEMP_ROOT/rollback-enabled"
mkdir -p "$rollback_available" "$rollback_enabled"
printf 'configuracao-anterior\n' > "$rollback_available/dev-automation-local.conf"
ln -s "$rollback_available/dev-automation-local.conf" "$rollback_enabled/dev-automation-local.conf"
cat > "$fake_bin/nginx-fail-apply" <<EOF_FAIL_NGINX
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$nginx_log"
if [[ "\$*" == '-t' ]]; then
  exit 1
fi
exit 0
EOF_FAIL_NGINX
chmod +x "$fake_bin/nginx-fail-apply"

if PATH="$fake_bin:$PATH" \
NGINX_BIN="$fake_bin/nginx-fail-apply" \
NGINX_AVAILABLE_DIR="$rollback_available" \
NGINX_ENABLED_DIR="$rollback_enabled" \
TLS_DIR="$TEMP_ROOT/rollback-tls" \
  "$SCRIPT" --install >/dev/null 2>&1; then
  fail 'instalação deveria falhar quando nginx -t final rejeita a configuração'
fi
grep -Fxq 'configuracao-anterior' "$rollback_available/dev-automation-local.conf" || fail 'configuração anterior não foi restaurada após falha'
[[ -L "$rollback_enabled/dev-automation-local.conf" ]] || fail 'symlink anterior não foi restaurado após falha'

printf 'OK: gateway Nginx local é genérico, Orbital-first, validado e idempotente\n'
