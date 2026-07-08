#!/usr/bin/env bash
# cd /home/daniel/Code/sind-infra/deploy/
set -euo pipefail

# -----------------------------------------------------------------------------
# sind-infra-clean-zoneidentifier.sh
#
# Monitora /home/daniel/Code/sind-infra e apaga arquivos *:Zone.Identifier
# em qualquer subpasta, em loop com timer.
#
# Uso:
#   chmod +x sind-infra-clean-zoneidentifier.sh
#   ./sind-infra-clean-zoneidentifier.sh
# -----------------------------------------------------------------------------

PROJECT_ROOT="/home/daniel/Code"

# Intervalo entre ciclos completos, em segundos.
INTERVAL_SECONDS=6

# De quanto em quanto tempo mostra a contagem regressiva.
COUNTDOWN_STEP_SECONDS=2

# 1 = exibir ações realizadas.
# 0 = silencioso, exceto início/erro/fim.
VERBOSE=1

# 1 = exibir resumo mesmo quando nada foi apagado.
SHOW_IDLE_SUMMARY=1

line() {
  echo "────────────────────────────────────────────────────────────"
}

now_text() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  if [ "$VERBOSE" = "1" ]; then
    echo "[$(now_text)] $*"
  fi
}

format_seconds() {
  local seconds="$1"
  local minutes rest

  if [ "$seconds" -lt 0 ]; then
    seconds=0
  fi

  minutes=$((seconds / 60))
  rest=$((seconds % 60))

  printf '%02d:%02d' "$minutes" "$rest"
}

clean_zone_identifier_once() {
  local removed
  removed=0

  log "Procurando Zone.Identifier dentro de:"
  log "  $PROJECT_ROOT"

  while IFS= read -r -d '' file; do
    log "  Apagando: $file"
    rm -f -- "$file"
    removed=$((removed + 1))
  done < <(find "$PROJECT_ROOT" -type f -name '*:Zone.Identifier' -print0 2>/dev/null)

  log "Resumo Zone.Identifier: apagados=$removed"
}

run_once() {
  local cycle="$1"

  if [ ! -d "$PROJECT_ROOT" ]; then
    echo "ERRO: PROJECT_ROOT não existe: $PROJECT_ROOT" >&2
    exit 1
  fi

  line
  log "Ciclo #$cycle iniciado."

  clean_zone_identifier_once

  if [ "$SHOW_IDLE_SUMMARY" = "1" ]; then
    log "Ciclo #$cycle finalizado. Próxima verificação em $(format_seconds "$INTERVAL_SECONDS")."
  fi
}

sleep_with_countdown() {
  local remaining step
  remaining="$INTERVAL_SECONDS"

  while [ "$remaining" -gt 0 ]; do
    if [ "$remaining" -lt "$COUNTDOWN_STEP_SECONDS" ]; then
      step="$remaining"
    else
      step="$COUNTDOWN_STEP_SECONDS"
    fi

    log "Aguardando próximo ciclo... faltam $(format_seconds "$remaining")"
    sleep "$step"
    remaining=$((remaining - step))
  done
}

stop() {
  echo
  line
  echo "Monitoramento encerrado."
  exit 0
}

trap stop INT TERM

line
echo "Monitor de limpeza Zone.Identifier iniciado"
line
echo "Projeto:               $PROJECT_ROOT"
echo "Intervalo de ciclo:    ${INTERVAL_SECONDS}s"
echo "Atualização da espera: ${COUNTDOWN_STEP_SECONDS}s"
echo "Para parar:            Ctrl+C"
line

clean_zoneidentifier_cycle=1

while true; do
  run_once "$clean_zoneidentifier_cycle"
  clean_zoneidentifier_cycle=$((clean_zoneidentifier_cycle + 1))
  sleep_with_countdown
done