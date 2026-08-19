#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
MODULE="$ROOT/scripts/dev-manager/190-config-gitcrypt-guard.sh"
GUARD="$ROOT/scripts/config-gitcrypt-guard.sh"

# O manager só corrige o escopo git-crypt quando o check detecta falha.
grep -Fq 'gitcrypt_guard_exec --check' "$MODULE"
grep -Fq 'gitcrypt_guard_exec --fix' "$MODULE"
grep -Fq '/home/daniel/static/git-reverse-crypt-2.key' "$MODULE"

# Não reintroduzir rotinas removidas.
! grep -Rqs 'merge_import_external' "$ROOT/scripts/dev-manager" "$ROOT/scripts/auto-code-manager.sh"
! grep -Rqs 'materialize_changed_protected' "$ROOT/scripts/dev-manager" "$ROOT/scripts/auto-code-manager.sh"
! grep -Rqs 'kill -USR1' "$ROOT/scripts/dev-manager" "$ROOT/scripts/auto-code-manager.sh"

# src/config de código não pode virar alvo git-crypt apenas pelo nome.
TMP="$(mktemp -d /tmp/dev-manager-gitcrypt-scope-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/Code/orgs/demo/apps/web/src/config" "$TMP/bin"
printf 'export const API = "/api";\n' > "$TMP/Code/orgs/demo/apps/web/src/config/api-url.ts"
printf 'orgs/demo\n' > "$TMP/projects"
git -C "$TMP/Code/orgs/demo" init -q
git -C "$TMP/Code/orgs/demo" config user.email test@example.invalid
git -C "$TMP/Code/orgs/demo" config user.name test
printf x > "$TMP/key"
PATH="$PATH" "$GUARD" --check --code-root "$TMP/Code" --projects-file "$TMP/projects" --key "$TMP/key" > "$TMP/out" 2>&1 || true
test ! -e "$TMP/Code/orgs/demo/.gitattributes"
grep -Fq '0 pastas config examinadas' "$TMP/out"

printf 'OK: autocorreção git-crypt continua limitada a configs sensíveis; src/config não entra por nome\n'
