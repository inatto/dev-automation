#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENTRY="$ROOT/scripts/auto-code-manager.sh"
MOD="$ROOT/scripts/dev-manager"

[ -x "$ENTRY" ]
[ -d "$MOD" ]
[ "$(wc -l < "$ENTRY")" -lt 100 ]

count="$(find "$MOD" -maxdepth 1 -type f -name '*.sh' | wc -l)"
[ "$count" -ge 10 ]
[ "$count" -le 20 ]

while IFS= read -r file; do
  bash -n "$file"
  lines="$(wc -l < "$file")"
  [ "$lines" -lt 400 ] || {
    echo "FALHOU: módulo grande demais ($lines linhas): $file" >&2
    exit 1
  }
done < <(find "$MOD" -maxdepth 1 -type f -name '*.sh' | sort)

bash -n "$ENTRY"
grep -Fq '900-main.sh' "$ENTRY"
printf 'OK: entrypoint pequeno + %s módulos contextuais (<400 linhas cada)\n' "$count"
