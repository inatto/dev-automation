#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
MODULE="$ROOT/scripts/dev-manager/190-config-gitcrypt-guard.sh"
MAIN="$ROOT/scripts/dev-manager/900-main.sh"
BACKUPS="$ROOT/scripts/dev-manager/130-backups.sh"
ATTRS="$ROOT/.gitattributes"
WRAPPER="$ROOT/scripts/dev-manager.sh"

# O suporte manual continua disponível.
grep -Fq 'args=(--unlock' "$MODULE"
grep -Fq -- '--git-crypt-audit' "$MAIN"
grep -Fq 'git-crypt|gitcrypt|config-crypt|security-config)' "$WRAPPER"

# Nunca mais criptografar config/** por atributo automático deste projeto.
! grep -Eq '^[[:space:]]*config/\*\*[[:space:]].*filter=git-crypt' "$ATTRS"
! grep -Fq 'BEGIN dev-manager: config folders git-crypt' "$ATTRS"

# Start normal e backup normal não podem chamar o guard.
STARTUP_TAIL="$(sed -n '/initialize_pause_control/,$p' "$MAIN")"
! grep -Fq 'gitcrypt_guard_all' <<< "$STARTUP_TAIL"
! grep -Fq 'gitcrypt_guard_project' "$BACKUPS"

printf 'OK: git-crypt somente manual; sem config/** automático, start ou backup\n'
