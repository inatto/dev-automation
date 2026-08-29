#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
CONFIG="$ROOT/config/services.csv"
PROJECTS="$ROOT/config/projects/default.projects"
NGINX="$ROOT/scripts/local-nginx.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

expected_host='monitor.amazon-infra.localhost'
expected_service="amazon-infra-monitor;base;4005;8005;${expected_host};/"
expected_project='infra/amazon-infra/apps/monitor-app'

grep -Fxq "$expected_service" "$CONFIG"
grep -Fxq "$expected_project" "$PROJECTS"

# local-nginx must not manage Windows/Linux hosts files. TLS hosts.txt is only
# the mkcert SAN inventory and is intentionally unrelated to /etc/hosts.
for forbidden in WINDOWS_HOSTS_FILE ensure_windows_host_resolution HOSTS_BLOCK_BEGIN 'drivers/etc/hosts' 'System32\drivers\etc\hosts'; do
  ! grep -Fq "$forbidden" "$NGINX"
done

"$NGINX" --validate >/dev/null
"$NGINX" --render > "$TMP/nginx.conf"

block="$TMP/monitor.conf"
awk -v target="$expected_host" '
  $0 ~ "server_name " target ";" {count++; if (count == 2) on=1}
  on {print}
  on && /^}$/ {exit}
' "$TMP/nginx.conf" > "$block"

grep -Fq "server_name $expected_host;" "$block"
grep -Fq 'ssl_certificate ' "$block"
grep -Fq 'ssl_certificate_key ' "$block"
grep -Fq 'location = /api {' "$block"
grep -Fq 'return 308 /api/;' "$block"
grep -Fq 'location /api/ {' "$block"
grep -Fq 'proxy_pass http://127.0.0.1:8005/;' "$block"
grep -Fq 'location / {' "$block"
grep -Fq 'proxy_pass http://127.0.0.1:4005;' "$block"

# Namespace global do subprojeto respeita o pai.
# shellcheck source=../scripts/project-names.sh
source "$ROOT/scripts/project-names.sh"
[[ "$(project_global_command_base "$expected_project" "$PROJECTS")" == 'amazon-infra--monitor-app' ]]

# Instalação simulada: certificado inclui o novo .localhost e é idempotente.
fake_bin="$TMP/bin"
available="$TMP/sites-available"
enabled="$TMP/sites-enabled"
tls="$TMP/tls"
mkdir -p "$fake_bin" "$available" "$enabled"
cat > "$fake_bin/nginx" <<'FAKE_NGINX'
#!/usr/bin/env bash
exit 0
FAKE_NGINX
cat > "$fake_bin/mkcert" <<'FAKE_MKCERT'
#!/usr/bin/env bash
if [[ "${1:-}" == '-CAROOT' ]]; then
  printf '%s\n' "${TMP_FAKE_CAROOT:?}"
  exit 0
fi
if [[ "${1:-}" == '-install' ]]; then
  mkdir -p "${TMP_FAKE_CAROOT:?}"
  printf 'fake-root-ca\n' > "$TMP_FAKE_CAROOT/rootCA.pem"
  exit 0
fi
cert=''
key=''
while (($#)); do
  case "$1" in
    -cert-file) cert="$2"; shift 2 ;;
    -key-file) key="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'fake-cert\n' > "$cert"
printf 'fake-key\n' > "$key"
FAKE_MKCERT
cat > "$fake_bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
exit 0
FAKE_SYSTEMCTL
chmod +x "$fake_bin/nginx" "$fake_bin/mkcert" "$fake_bin/systemctl"

TMP_FAKE_CAROOT="$TMP/caroot" PATH="$fake_bin:$PATH" NGINX_BIN=nginx \
  NGINX_AVAILABLE_DIR="$available" NGINX_ENABLED_DIR="$enabled" TLS_DIR="$tls" \
  "$NGINX" --install >/dev/null
cp "$available/dev-automation-local.conf" "$TMP/installed-one.conf"
grep -Fxq "$expected_host" "$tls/hosts.txt"

TMP_FAKE_CAROOT="$TMP/caroot" PATH="$fake_bin:$PATH" NGINX_BIN=nginx \
  NGINX_AVAILABLE_DIR="$available" NGINX_ENABLED_DIR="$enabled" TLS_DIR="$tls" \
  "$NGINX" --install >/dev/null
cmp -s "$TMP/installed-one.conf" "$available/dev-automation-local.conf"

printf 'OK: %s HTTPS local sem hosts, Web 4005, API 8005, certificado e amazon-infra--monitor-app\n' "$expected_host"
