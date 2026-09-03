#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TARGET="${HOME}/.local/bin/amazon-imap-bot"

mkdir -p "$(dirname "$TARGET")"
ln -sfn "$HERE/run.sh" "$TARGET"

echo "Comando global instalado/atualizado:"
echo "  amazon-imap-bot"
echo
echo "Se ~/.local/bin ainda não estiver no PATH, reabra a sessão do terminal."
