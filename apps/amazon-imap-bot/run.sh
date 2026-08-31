#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
VENV="$HERE/.venv"
PYTHON="$VENV/bin/python"
REQUIREMENTS="$HERE/requirements.txt"

printf '[amazon-imap-bot] launcher: iniciando em %s\n' "$HERE" >&2

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
  else
    printf '[amazon-imap-bot] launcher: ambiente Python OK (%s)\n' "$PYTHON" >&2
  fi

  if ! "$PYTHON" -c 'import boto3, openai, oracledb' >/dev/null 2>&1; then
    printf '[amazon-imap-bot] instalando dependências...
' >&2
    "$PYTHON" -m pip install -r "$REQUIREMENTS"
  else
    printf '[amazon-imap-bot] launcher: dependências OK\n' >&2
  fi
}

bootstrap_venv
export PYTHONUNBUFFERED=1
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
printf '[amazon-imap-bot] launcher: executando aplicação\n' >&2
exec "$PYTHON" "$HERE/__main__.py" "$@"
