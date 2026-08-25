#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED="$HOME/Code/bots/dev-automation/apps/voice-commands"
if [[ "$HERE" != "$EXPECTED" ]]; then
  echo "ERRO: para usar o serviço padrão, deixe o projeto em $EXPECTED" >&2
  exit 1
fi
mkdir -p "$HOME/.config/systemd/user"
install -m 0644 "$HERE/voice-commands.service" "$HOME/.config/systemd/user/voice-commands.service"
systemctl --user daemon-reload
systemctl --user enable voice-commands.service
systemctl --user restart voice-commands.service
systemctl --user --no-pager --full status voice-commands.service || true
