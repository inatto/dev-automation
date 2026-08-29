#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
VENV="$HERE/.venv"
PYTHON="$VENV/bin/python"
REQUIREMENTS="$HERE/requirements.txt"

bootstrap_venv() {
  local system_python
  system_python="$(command -v python3 || true)"
  if [[ -z "$system_python" ]]; then
    printf '[amazon-imap-bot] ERRO: python3 não encontrado.
' >&2
    exit 1
  fi

  if [[ ! -x "$PYTHON" ]]; then
    printf '[amazon-imap-bot] preparando ambiente Python...
' >&2
    "$system_python" -m venv "$VENV"
  fi

  if ! "$PYTHON" -c 'import boto3, openai' >/dev/null 2>&1; then
    printf '[amazon-imap-bot] instalando dependências...
' >&2
    "$PYTHON" -m pip install -r "$REQUIREMENTS"
  fi
}

bootstrap_venv
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
exec "$PYTHON" "$HERE/__main__.py" "$@"
