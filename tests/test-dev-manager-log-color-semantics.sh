#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TUI="$ROOT/scripts/dev-manager-tui.py"
LOGGING="$ROOT/scripts/dev-manager/20-status-logging.sh"
IMPORTS="$ROOT/scripts/dev-manager/70-imports.sh"
BACKUPS="$ROOT/scripts/dev-manager/130-backups.sh"

# Contexto é transmitido estruturado ao ncurses. Cor não depende de palavras
# encontradas em nomes/caminhos de arquivo.
grep -Fq '@@DEVCTX:%s@@[%s] %s' "$LOGGING"
grep -Fq 'split_log_context' "$TUI"
grep -Fq '"backup": self.colors["ok"]' "$TUI"
grep -Fq '"downloads": self.colors["download"]' "$TUI"
grep -Fq '"sql": self.colors["sql"]' "$TUI"
grep -Fq '"warning": self.colors["warning"]' "$TUI"
grep -Fq '"error": self.colors["error"]' "$TUI"

# Backup continua semanticamente marcado, logo "Gerando backup" volta a ser
# destacado/negrito sem heurística de texto no TUI.
grep -Fq 'log "Gerando backup:' "$BACKUPS"
grep -Fq 'if LOG_CONTEXT=backup backup_all' "$ROOT/scripts/dev-manager/900-main.sh"

# Erro real é explicitamente ERRO; resumo com zero falhas segue download_done.
grep -Fq 'log "ERRO: falha ao importar:' "$IMPORTS"
grep -Fq 'LOG_CONTEXT=download_done log "LOTE DE DOWNLOADS CONCLUÍDO:' "$IMPORTS"

# Regressão do dev-status-unzip.svg: nenhuma regra interna procura UNZIP no texto.
! grep -Fq '"UNZIP" in upper' "$TUI"

printf 'OK: cores por contexto estruturado; backup destacado; vermelho só para erro\n'
