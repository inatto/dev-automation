#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
MODULE="$ROOT/scripts/dev-manager/190-config-gitcrypt-guard.sh"
GUARD="$ROOT/scripts/config-gitcrypt-guard.sh"
! grep -Eq 'cat .*\.gitattributes|>.*\.gitattributes|git .* add .*\.gitattributes|update-index|hash-object.*--path|git-crypt init|crypt init' "$GUARD"
! grep -Fq -- '--fix' "$MODULE"
grep -Fq -- '--unlock' "$MODULE"
echo 'OK: nenhum efeito colateral de projeto no fluxo git-crypt'
