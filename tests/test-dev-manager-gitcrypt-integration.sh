#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENTRY="$ROOT/scripts/auto-code-manager.sh"
MODULE="$ROOT/scripts/dev-manager/190-config-gitcrypt-guard.sh"
BACKUPS="$ROOT/scripts/dev-manager/130-backups.sh"
MANAGER="$ROOT/scripts/dev-manager.sh"

[ -x "$ROOT/scripts/config-gitcrypt-guard.sh" ]
grep -Fq '190-config-gitcrypt-guard.sh' "$ENTRY"
grep -Fq 'gitcrypt_guard_project "$project" || true' "$BACKUPS"
grep -Fq 'taskbar_status error "CRÍTICO: config sem git-crypt"' "$MODULE"
grep -Fq 'error_beep' "$MODULE"
grep -Fq 'DEV_MANAGER_GIT_CRYPT_KEY:-/home/daniel/static/git-reverse-crypt-2.key' "$MODULE"
grep -Fq 'git-crypt|gitcrypt|config-crypt|security-config)' "$MANAGER"
grep -Fq -- '--git-crypt-audit' "$ROOT/scripts/dev-manager/900-main.sh"
grep -Fq 'gitcrypt_guard_all || true' "$ROOT/scripts/dev-manager/900-main.sh"
grep -Fq 'INSTALAR GIT-CRYPT:' "$MODULE"
grep -Fq 'sudo apt update && sudo apt install -y git-crypt' "$ROOT/scripts/config-gitcrypt-guard.sh"
printf 'OK: dev-manager chama guard desacoplado, alerta crítico vermelho/som e possui auditoria manual e automática na inicialização\n'
