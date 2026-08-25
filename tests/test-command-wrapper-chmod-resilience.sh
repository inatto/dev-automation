#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# dev-manager deve autorreparar/reinstalar os comandos antes de iniciar.
grep -A8 -F 'start|run)' "$ROOT/scripts/dev-manager.sh" | grep -Fq 'refresh_global_commands'

# Wrappers shell não podem depender do bit +x dos scripts internos.
grep -Fq 'exec bash "$source_file"' "$ROOT/deploy/local/install-commands.sh"
grep -Fq 'exec bash "$COMMAND_RUNNER"' "$ROOT/deploy/local/install-project-commands.sh"
grep -Fq 'exec bash "$SOURCE"' "$ROOT/deploy/local/install-dev-manager.sh"
grep -Fq 'exec bash "$lrdp_source"' "$ROOT/deploy/local/install-commands.sh"

# O instalador continua restaurando +x nos scripts de origem como autorreparo.
grep -Fq '"$G512_RGB_SOURCE"' "$ROOT/deploy/local/install-commands.sh"
grep -Fq '"$PROJECT_RUNNER"' "$ROOT/deploy/local/install-commands.sh"
grep -Fq '"$DESKTOPS_SOURCE"' "$ROOT/deploy/local/install-commands.sh"
grep -Fq '"$LRDP_TUI_SOURCE"' "$ROOT/deploy/local/install-commands.sh"
grep -Fq '"$LRDP1_SOURCE"' "$ROOT/deploy/local/install-commands.sh"
grep -Fq '"$LRDP2_SOURCE"' "$ROOT/deploy/local/install-commands.sh"

echo 'OK: dev-manager autorrepara comandos e wrappers shell toleram perda de +x interno'
