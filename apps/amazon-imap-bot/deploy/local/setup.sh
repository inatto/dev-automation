#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDS=()
cleanup(){ ((${#PIDS[@]})) && kill "${PIDS[@]}" 2>/dev/null || true; wait 2>/dev/null || true; }
trap cleanup INT TERM EXIT
echo "Preparando API e Web do Amazon IMAP Bot..."
"$SCRIPT_DIR/setup-api.sh" & PIDS+=("$!")
"$SCRIPT_DIR/setup-web.sh" & PIDS+=("$!")
wait -n "${PIDS[@]}"
