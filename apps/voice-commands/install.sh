#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

MODE="auto"
case "${1:-}" in
  "") ;;
  --gpu) MODE="gpu" ;;
  --cpu) MODE="cpu" ;;
  --auto) MODE="auto" ;;
  -h|--help)
    cat <<'MSG'
Uso: ./install.sh [--gpu|--cpu|--auto]

  --gpu   instala cuBLAS CUDA 12 + cuDNN 9 dentro do .venv
  --cpu   instala somente as dependências comuns
  --auto  usa GPU quando nvidia-smi detectar uma NVIDIA (padrão)
MSG
    exit 0
    ;;
  *)
    echo "ERRO: opção inválida: $1" >&2
    exit 2
    ;;
esac

python3 -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt

if [[ "$MODE" == "auto" ]]; then
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    MODE="gpu"
  else
    MODE="cpu"
  fi
fi

if [[ "$MODE" == "gpu" ]]; then
  echo "Instalando runtime GPU local: CUDA 12 cuBLAS + cuDNN 9..."
  python -m pip install -r requirements-gpu.txt
else
  echo "GPU não solicitada/detectada; runtime NVIDIA do venv não será instalado."
fi

cat <<'MSG'

Instalado.

Para ir DIRETO a um desktop específico (inclusive GNOME/Wayland):
  sudo apt install wmctrl

Para avançar/recuar relativamente no X11:
  sudo apt install xdotool

Para avançar/recuar relativamente no Wayland, use ydotool (com ydotoold ativo):
  sudo apt install ydotool

Diagnóstico de GPU/Whisper:
  ./run.sh --doctor

Para testar sem executar atalhos:
  ./run.sh --stdin --dry-run

Para ouvir o microfone:
  ./run.sh
MSG

./run.sh --doctor || true
