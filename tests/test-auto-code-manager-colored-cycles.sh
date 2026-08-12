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

grep -Fq 'Executa, nesta ordem: importar ZIPs, compactar SQLs' "$SCRIPT"
grep -Fq 'Procura ZIPs em Downloads, identifica o projeto correspondente' "$SCRIPT"
grep -Fq 'Procura arquivos .sql nas pastas configuradas' "$SCRIPT"
grep -Fq 'Remove arquivos residuais :Zone.Identifier' "$SCRIPT"
grep -Fq 'Gera somente os ZIPs explicitamente configurados' "$SCRIPT"
grep -Fq 'Nenhum backup agora; será executado quando completar o intervalo' "$SCRIPT"

printf 'OK: todos os contextos exibem descrição objetiva no início ou motivo quando aguardam\n'
