#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SCRIPT="$PROJECT_ROOT/scripts/local-nginx.sh"
TEMP_ROOT="$(mktemp -d /tmp/local-nginx-upload-limit-test-XXXXXX)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

fail() { printf 'FALHOU: %s\n' "$*" >&2; exit 1; }

config="$TEMP_ROOT/default.conf"
TLS_DIR="$TEMP_ROOT/tls" "$SCRIPT" --render > "$config"

grep -Fq 'client_max_body_size 32m;' "$config" || fail 'limite padrão 32m não foi renderizado'

admin_block="$TEMP_ROOT/admin.conf"
awk '/server_name admin\.localhost;/{count++; if (count == 2) on=1} on{print} on && /^}$/{exit}' "$config" > "$admin_block"
grep -Fq 'client_max_body_size 32m;' "$admin_block" || fail 'admin.localhost não recebeu limite 32m'

custom="$TEMP_ROOT/custom.conf"
CLIENT_MAX_BODY_SIZE=48m TLS_DIR="$TEMP_ROOT/tls" "$SCRIPT" --render > "$custom"
grep -Fq 'client_max_body_size 48m;' "$custom" || fail 'override 48m não foi aplicado'
! grep -Fq 'client_max_body_size 32m;' "$custom" || fail 'override manteve o limite padrão'

if CLIENT_MAX_BODY_SIZE=nope TLS_DIR="$TEMP_ROOT/tls" "$SCRIPT" --render >/dev/null 2>"$TEMP_ROOT/error.log"; then
  fail 'valor inválido deveria falhar'
fi
grep -Fq 'CLIENT_MAX_BODY_SIZE inválido: nope' "$TEMP_ROOT/error.log" || fail 'erro de validação ausente'

printf 'OK: gateway local aceita uploads até 32m por padrão e valida override\n'
