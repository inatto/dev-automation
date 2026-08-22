#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDS=()
cleanup(){ ((${#PIDS[@]})) && kill "${PIDS[@]}" 2>/dev/null || true; wait 2>/dev/null || true; }
trap cleanup INT TERM EXIT
"$SCRIPT_DIR/start-web.sh" & PIDS+=("$!")
"$SCRIPT_DIR/start-api.sh" & PIDS+=("$!")
wait -n "${PIDS[@]}"
