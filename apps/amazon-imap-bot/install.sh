#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$HERE"
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
printf '\nAmazon IMAP Bot instalado.\n'
printf 'Execute: amazon-imap-bot\n'
printf 'Diagnóstico: amazon-imap-bot --doctor\n'
