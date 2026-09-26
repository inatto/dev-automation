#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
if find "$ROOT/scripts" -maxdepth 1 -type f -print -quit | grep -q .; then
  echo 'ERRO: scripts/ deve conter apenas pastas; há arquivo solto na raiz.' >&2
  find "$ROOT/scripts" -maxdepth 1 -type f -printf '%f\n' >&2
  exit 1
fi
required=(core chromes files pycharms phpstorms terminals desktops dev-manager dev-status project project-sync gitcrypt nginx g512 chatgpts amazon-imap-bot environment maintenance 'Global Shortcuts')
for dir in "${required[@]}"; do
  [[ -d "$ROOT/scripts/$dir" ]] || { echo "ERRO: pasta ausente: scripts/$dir" >&2; exit 1; }
done
printf 'OK: scripts/ sem arquivos soltos; módulos agrupados por responsabilidade.\n'
