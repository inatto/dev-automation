#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SCRIPT="$PROJECT_ROOT/scripts/auto-code-manager.sh"

grep -Fq 'run_stage downloads "DOWNLOADS INICIAIS"' "$SCRIPT"
grep -Fq 'run_stage sql "SQLs INICIAIS"' "$SCRIPT"
grep -Fq 'run_stage zone "LIMPEZA ZONE.IDENTIFIER INICIAL"' "$SCRIPT"
grep -Fq 'stage backup start "BACKUP INTELIGENTE — INÍCIO"' "$SCRIPT"
grep -Fq 'run_stage downloads "DOWNLOAD / IMPORTAÇÃO"' "$SCRIPT"
grep -Fq 'run_stage sql "SQL → ZIP"' "$SCRIPT"
grep -Fq '[ "${NO_COLOR:-}" = "" ]' "$SCRIPT"

# O ciclo de polling antigo deve ter desaparecido.
! grep -Fq 'CICLO #$cycle' "$SCRIPT"
! grep -Fq 'sleep_with_pause' "$SCRIPT"
! grep -Fq 'INTERVAL=' "$SCRIPT"
! grep -Fq 'ZONE_EVERY=' "$SCRIPT"

grep -Fq 'ZIP detectado pelo filesystem; importa somente este arquivo, sem varrer Downloads.' "$SCRIPT"
grep -Fq 'SQL detectado pelo filesystem; compacta somente a pasta afetada.' "$SCRIPT"
grep -Fq 'IDLE event-driven: aguardando inotify' "$SCRIPT"
grep -Fq 'Estado ocioso real: este read não tem timeout e não consome CPU enquanto' "$SCRIPT"
grep -Fq 'Compacta somente projetos alterados e agregadores dependentes.' "$SCRIPT"

printf 'OK: estados coloridos permanecem e o polling antigo foi substituído por espera event-driven\n'
