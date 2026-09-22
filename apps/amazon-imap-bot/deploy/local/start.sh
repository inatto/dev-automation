#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDS=()

cleanup() {
  trap - INT TERM EXIT

  # Cada wrapper roda como líder da própria sessão. Sinaliza o wrapper para
  # que ele encerre, de forma controlada, o processo Web/API que supervisiona.
  for pid in "${PIDS[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done

  for _ in {1..35}; do
    alive=0
    for pid in "${PIDS[@]}"; do
      kill -0 "$pid" 2>/dev/null && alive=1
    done
    [[ "$alive" -eq 0 ]] && break
    sleep 0.1
  done

  # Último recurso: como o wrapper foi iniciado com setsid, PID = PGID.
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    fi
  done

  wait 2>/dev/null || true
}

trap cleanup INT TERM EXIT

echo "Iniciando Amazon IMAP Bot Web + API. Ctrl+C encerra."
setsid "$SCRIPT_DIR/start-api.sh" & PIDS+=("$!")
setsid "$SCRIPT_DIR/start-web.sh" & PIDS+=("$!")
wait -n "${PIDS[@]}"
