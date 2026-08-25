#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$HERE/.venv/bin/python"

if [[ ! -x "$PYTHON" ]]; then
  echo "ERRO: ambiente Python ausente em $HERE/.venv. Rode: $HERE/install.sh --gpu" >&2
  exit 1
fi

# As bibliotecas NVIDIA instaladas por pip ficam dentro do venv. O loader
# precisa conhecê-las antes de o Python/CTranslate2 iniciar.
NVIDIA_LIB_DIRS="$($PYTHON - <<'PYLIBS'
from importlib import import_module
from pathlib import Path

paths = []
for name in ("nvidia.cublas.lib", "nvidia.cudnn.lib"):
    try:
        module = import_module(name)
    except Exception:
        continue
    module_paths = list(getattr(module, "__path__", []) or [])
    if module_paths:
        candidate = Path(module_paths[0]).resolve()
    else:
        filename = getattr(module, "__file__", None)
        if not filename:
            continue
        candidate = Path(filename).resolve().parent
    text = str(candidate)
    if candidate.is_dir() and text not in paths:
        paths.append(text)
print(":".join(paths))
PYLIBS
)"

if [[ -n "$NVIDIA_LIB_DIRS" ]]; then
  export LD_LIBRARY_PATH="$NVIDIA_LIB_DIRS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

exec "$PYTHON" "$HERE/voice_commands.py" "$@"
