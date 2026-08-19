#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

MODULE="$ROOT/scripts/dev-manager/190-config-gitcrypt-guard.sh"
IMPORTS="$ROOT/scripts/dev-manager/70-imports.sh"
INOTIFY="$ROOT/scripts/dev-manager/170-inotify-runtime.sh"
LIGHT="$ROOT/scripts/dev-manager/140-light-monitor.sh"
ENTRY="$ROOT/scripts/auto-code-manager.sh"
GUARD="$ROOT/scripts/config-gitcrypt-guard.sh"

# Manager só audita git-crypt. Nenhum fix automático.

# Start do dev-manager não dispara auxiliares não relacionados.
START_BLOCK="$(sed -n '/start|run)/,/^    ;;/p' "$ROOT/scripts/dev-manager.sh")"
! grep -Fq 'refresh_global_commands' <<<"$START_BLOCK"
! grep -Fq 'ensure_dev_status' <<<"$START_BLOCK"
! grep -Fq 'ensure_g512_rgb' <<<"$START_BLOCK"
grep -Fq 'local -a args=(--check ' "$MODULE"
! grep -Fq 'local -a args=(--fix ' "$MODULE"

# Importação não cria/mescla .external e não reinicia processo.
! grep -Fq 'merge_import_external_configs' "$IMPORTS"
! grep -Fq 'materialize_changed_protected_configs' "$IMPORTS"
! grep -Fq 'notify_running_project_update' "$IMPORTS"
! grep -Fq '120-external-merge.sh' "$ENTRY"

# SQL não possui automação implícita no monitor.
! grep -Fq 'SQL detectado pelo filesystem' "$INOTIFY"
! grep -Fq 'SQL detectado no monitor leve' "$LIGHT"

# src/config de código não pode virar alvo git-crypt apenas pelo nome.
TMP="$(mktemp -d /tmp/dev-manager-gitcrypt-readonly-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/Code/orgs/demo/apps/web/src/config"
printf 'export const API = "/api";\n' > "$TMP/Code/orgs/demo/apps/web/src/config/api-url.ts"
git -C "$TMP/Code/orgs/demo" init -q
git -C "$TMP/Code/orgs/demo" config user.email test@example.invalid
git -C "$TMP/Code/orgs/demo" config user.name Test
git -C "$TMP/Code/orgs/demo" add apps/web/src/config/api-url.ts
git -C "$TMP/Code/orgs/demo" commit -qm init
printf 'orgs/demo\n' > "$TMP/projects"
printf 'dummy-key\n' > "$TMP/key"

DEV_MANAGER_PROJECTS_FILE="$TMP/projects" CODE_ROOT="$TMP/Code" \
  "$GUARD" --check --code-root "$TMP/Code" --projects-file "$TMP/projects" --key "$TMP/key" \
  > "$TMP/out.log"

test ! -e "$TMP/Code/orgs/demo/.gitattributes"
grep -Fq '0 pastas config examinadas' "$TMP/out.log"
test -f "$TMP/Code/orgs/demo/apps/web/src/config/api-url.ts"

printf 'OK: manager não gera .gitattributes/api-url, não faz .external/restart/SQL automático\n'
