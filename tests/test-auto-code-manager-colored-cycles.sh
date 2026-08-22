#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SCRIPT="$PROJECT_ROOT/scripts/auto-code-manager.sh"
SOURCES=("$SCRIPT" "$PROJECT_ROOT"/scripts/dev-manager/*.sh)

grep -Fq 'if is_wsl_runtime; then' "${SOURCES[@]}"
grep -Fq 'run_stage zone "LIMPEZA ZONE.IDENTIFIER INICIAL"' "${SOURCES[@]}"
grep -Fq 'stage backup start "BACKUP INTELIGENTE — INÍCIO"' "${SOURCES[@]}"
grep -Fq '[ "${NO_COLOR:-}" = "" ]' "${SOURCES[@]}"

# O ciclo de polling antigo deve ter desaparecido.
! grep -Fq 'CICLO #$cycle' "${SOURCES[@]}"
! grep -Fq 'sleep_with_pause' "${SOURCES[@]}"
! grep -Fq 'INTERVAL=' "${SOURCES[@]}"
! grep -Fq 'ZONE_EVERY=' "${SOURCES[@]}"

grep -Fq 'IDLE event-driven:' "${SOURCES[@]}"
grep -Fq 'Estado ocioso real: este read não tem timeout e não consome CPU enquanto' "${SOURCES[@]}"
grep -Fq 'Compacta somente projetos alterados e agregadores dependentes.' "${SOURCES[@]}"

! grep -Fq 'SQL detectado no monitor leve' "${SOURCES[@]}"
printf 'OK: estados coloridos permanecem, sem SQL automático e sem polling antigo\n'
