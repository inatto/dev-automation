#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$HERE"

python3 -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt

if ! python - <<'PY' >/dev/null 2>&1
import sounddevice
sounddevice.query_devices()
PY
then
  printf '\nAVISO: PortAudio não respondeu. Para habilitar o microfone no Ubuntu:\n' >&2
  printf '  sudo apt install libportaudio2 portaudio19-dev\n' >&2
fi

printf '\nGPT Console instalado.\n'
printf 'Execute: gpt-console\n'
printf 'Diagnóstico: gpt-console --doctor\n'
