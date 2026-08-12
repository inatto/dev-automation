#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SCRIPT="$PROJECT_ROOT/scripts/auto-code-manager.sh"

grep -Fq 'stage cycle start "CICLO #$cycle — INÍCIO"' "$SCRIPT"
grep -Fq 'run_stage downloads "DOWNLOADS / IMPORTAÇÃO"' "$SCRIPT"
grep -Fq 'run_stage sql "SQL → ZIP"' "$SCRIPT"
grep -Fq 'run_stage zone "LIMPEZA ZONE.IDENTIFIER INICIAL"' "$SCRIPT"
grep -Fq 'stage backup start "BACKUP INTELIGENTE — INÍCIO"' "$SCRIPT"
grep -Fq 'stage cycle end "CICLO #$cycle — CONCLUÍDO"' "$SCRIPT"
grep -Fq '[ "${NO_COLOR:-}" = "" ]' "$SCRIPT"

printf 'OK: contextos dos ciclos possuem cores e marcos de início/fim\n'

grep -Fq 'Importa ZIPs/SQLs e processa somente alterações reais detectadas via inotify' "$SCRIPT"
grep -Fq 'Procura ZIPs em Downloads, identifica o projeto correspondente' "$SCRIPT"
grep -Fq 'Procura arquivos .sql nas pastas configuradas' "$SCRIPT"
grep -Fq 'novos sidecars são tratados por evento' "$SCRIPT"
grep -Fq 'Compacta somente os projetos alterados e os agregadores que dependem deles' "$SCRIPT"
grep -Fq 'Backup pendente:' "$SCRIPT"

printf 'OK: ciclos descrevem o fluxo inteligente por eventos e o debounce do backup\n'
