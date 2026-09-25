#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
grep -Fq "ddl_zip) printf '1;38;5;208'" "$ROOT/scripts/dev-manager/20-status-logging.sh"
grep -Fq '"ddl_zip": self.colors["ddl_zip"]' "$ROOT/scripts/dev-manager/dev-manager-tui.py"
grep -Fq 'LOG_CONTEXT=ddl_zip log "◆ ZIP DDL:' "$ROOT/scripts/dev-manager/90-sql-zip.sh"
grep -Fq 'scripts/core/clear-terminal.sh' "$ROOT/deploy/local/install-dev-manager.sh"
grep -Fq 'scripts/dev-manager/dev-manager.sh' "$ROOT/deploy/local/install-dev-manager.sh"
echo 'OK: cor exclusiva DDL ZIP + wrapper dev-manager aponta para estrutura reorganizada'
