#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SCRIPT="$PROJECT_ROOT/scripts/local-nginx.sh"
TEMP_ROOT="$(mktemp -d /tmp/local-nginx-existing-tls-test-XXXXXX)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

fail() { printf 'FALHOU: %s\n' "$*" >&2; exit 1; }

BIN_DIR="$TEMP_ROOT/bin"
AVAILABLE_DIR="$TEMP_ROOT/sites-available"
ENABLED_DIR="$TEMP_ROOT/sites-enabled"
TLS_DIR="$TEMP_ROOT/tls"
mkdir -p "$BIN_DIR" "$AVAILABLE_DIR" "$ENABLED_DIR" "$TLS_DIR/ca"

cat > "$BIN_DIR/nginx" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$BIN_DIR/systemctl" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "is-active" ]]; then exit 0; fi
exit 0
MOCK
cat > "$BIN_DIR/sudo" <<'MOCK'
#!/usr/bin/env bash
exec "$@"
MOCK
cat > "$BIN_DIR/openssl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$BIN_DIR/mkcert" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
  -install) exit 0 ;;
  -CAROOT) printf '%s\n' '$TLS_DIR/ca'; exit 0 ;;
esac
exit 0
MOCK
cat > "$BIN_DIR/certutil.exe" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$BIN_DIR/wslpath" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}"
MOCK
chmod +x "$BIN_DIR"/*

printf 'test-ca\n' > "$TLS_DIR/ca/rootCA.pem"
printf 'existing-cert\n' > "$TLS_DIR/cert.pem"
printf 'existing-key\n' > "$TLS_DIR/key.pem"
awk -F';' 'NR > 1 && !seen[$5]++ {print $5}' "$PROJECT_ROOT/config/services.csv" > "$TLS_DIR/hosts.txt"
printf '*.admin.localhost\n' >> "$TLS_DIR/hosts.txt"

PATH="$BIN_DIR:$PATH" \
NGINX_AVAILABLE_DIR="$AVAILABLE_DIR" \
NGINX_ENABLED_DIR="$ENABLED_DIR" \
TLS_DIR="$TLS_DIR" \
NGINX_BIN=nginx \
MKCERT_BIN=mkcert \
"$SCRIPT" --install > "$TEMP_ROOT/output.log"

MANAGED_FILE="$AVAILABLE_DIR/dev-automation-local.conf"
[[ -f "$MANAGED_FILE" ]] || fail '--install parou antes de gravar a configuração com TLS já atualizado'
grep -Fq 'client_max_body_size 32m;' "$MANAGED_FILE" || fail 'limite 32m não foi instalado'
grep -Fq 'gateways HTTPS locais atualizados' "$TEMP_ROOT/output.log" || fail '--install não chegou ao fim'

printf 'OK: --install continua normalmente quando o TLS já está atualizado\n'
