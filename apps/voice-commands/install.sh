#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

python3 -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt

cat <<'MSG'
Instalado.

Para X11, confirme que xdotool existe:
  sudo apt install xdotool

Para Wayland, prefira ydotool (com ydotoold ativo) ou wtype quando suportado:
  sudo apt install ydotool

Para testar sem executar atalhos:
  .venv/bin/python voice_commands.py --stdin --dry-run

Para diagnóstico:
  .venv/bin/python voice_commands.py --doctor

Para ouvir o microfone:
  .venv/bin/python voice_commands.py
MSG
