#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
MODULE="$ROOT/scripts/dev-manager/190-config-gitcrypt-guard.sh"
grep -Fq 'args=(--unlock' "$MODULE"
! grep -Fq -- '--fix' "$MODULE"
! grep -Fq 'git add' "$MODULE"
! grep -Fq 'gitattributes' "$MODULE" || grep -Fq 'Não cria/edita .gitattributes' "$MODULE"
echo 'OK: integração dev-manager usa somente unlock'
