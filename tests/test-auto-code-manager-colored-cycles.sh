#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SCRIPT="$PROJECT_ROOT/scripts/auto-code-manager.sh"

grep -Fq 'stage cycle start "CICLO #$cycle — INÍCIO"' "$SCRIPT"
grep -Fq 'run_stage downloads "DOWNLOADS / IMPORTAÇÃO"' "$SCRIPT"
grep -Fq 'run_stage sql "SQL → ZIP"' "$SCRIPT"
grep -Fq 'run_stage zone "LIMPEZA ZONE.IDENTIFIER"' "$SCRIPT"
grep -Fq 'stage backup start "BACKUP — INÍCIO"' "$SCRIPT"
grep -Fq 'stage cycle end "CICLO #$cycle — CONCLUÍDO"' "$SCRIPT"
grep -Fq '[ "${NO_COLOR:-}" = "" ]' "$SCRIPT"

printf 'OK: contextos dos ciclos possuem cores e marcos de início/fim\n'
