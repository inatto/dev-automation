#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGGING="$ROOT/scripts/dev-manager/20-status-logging.sh"
LEGACY="$ROOT/scripts/dev-manager/10-tui-legacy.sh"
TUI="$ROOT/scripts/dev-manager-tui.py"
BACKUPS="$ROOT/scripts/dev-manager/130-backups.sh"
IMPORTS="$ROOT/scripts/dev-manager/70-imports.sh"
DIRTY="$ROOT/scripts/dev-manager/160-dirty-backups.sh"

grep -Fq "subproject) printf '1;38;5;169'" "$LOGGING"
grep -Fq 'context="subproject"' "$LOGGING"
grep -Fq "subproject) color='44;38;5;169;1'" "$LEGACY"
grep -Fq 'subproject = self.color_number(169, curses.COLOR_MAGENTA)' "$TUI"
grep -Fq '"subproject": curses.color_pair(15) | curses.A_BOLD' "$TUI"
grep -Fq '"subproject": self.colors["subproject"]' "$TUI"
grep -Fq 'local LOG_PROJECT="$project"' "$BACKUPS"
grep -Fq 'local LOG_PROJECT="$project"' "$IMPORTS"
grep -Fq 'local LOG_PROJECT="$project"' "$DIRTY"

# Valida o contexto sem depender de TTY/cor real.
(
  set -euo pipefail
  PROJECTS_FILE=/tmp/projects-test
  CODE_ROOT=/tmp/code-test
  TUI_ACTIVE=false
  DEV_MANAGER_TUI_CHILD=1
  registered_parent_project() {
    [ "$1" = "pai/apps/filho" ] && printf 'pai\n' || true
  }
  source "$LOGGING"
  LOG_PROJECT='pai/apps/filho' LOG_CONTEXT=zip_file log 'Gerando backup: pai/apps/filho -> filho.zip'
) | grep -Fq '@@DEVCTX:subproject@@'

printf 'OK: operações de subprojeto usam violeta neon/malva 169 em logs, backup, import e TUI\n'
