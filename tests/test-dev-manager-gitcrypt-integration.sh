#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
MODULE="$ROOT/scripts/dev-manager/190-config-gitcrypt-guard.sh"
ENTRY="$ROOT/scripts/auto-code-manager.sh"
MANAGER="$ROOT/scripts/dev-manager.sh"
BACKUPS="$ROOT/scripts/dev-manager/130-backups.sh"

[ -x "$ROOT/scripts/config-gitcrypt-guard.sh" ]
grep -Fq '190-config-gitcrypt-guard.sh' "$ENTRY"
grep -Fq 'gitcrypt_guard_project "$project" || true' "$BACKUPS"
grep -Fq 'taskbar_status error "CRÍTICO: config sem git-crypt"' "$MODULE"
grep -Fq 'gitcrypt_guard_exec --check' "$MODULE"
grep -Fq 'gitcrypt_guard_exec --fix' "$MODULE"
grep -Fq 'GIT-CRYPT: tentando autocorreção com a chave' "$MODULE"
grep -Fq 'DEV_MANAGER_GIT_CRYPT_KEY:-/home/daniel/static/git-reverse-crypt-2.key' "$MODULE"
grep -Fq 'git-crypt|gitcrypt|config-crypt|security-config)' "$MANAGER"
grep -Fq -- '--git-crypt-audit' "$ROOT/scripts/dev-manager/900-main.sh"
grep -Fq 'gitcrypt_guard_all || true' "$ROOT/scripts/dev-manager/900-main.sh"
grep -Fq 'sudo apt update && sudo apt install -y git-crypt' "$ROOT/scripts/config-gitcrypt-guard.sh"
printf 'OK: dev-manager faz check -> fix com chave padrão -> check final quando detecta erro git-crypt\n'
