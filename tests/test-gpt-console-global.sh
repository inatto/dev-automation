#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
INSTALLER="$ROOT/deploy/local/install-commands.sh"
APP="$ROOT/apps/gpt-console"

[[ -f "$APP/run.sh" ]]
[[ -f "$APP/gpt_console/tui.py" ]]
grep -Fq 'GPT_CONSOLE_SOURCE="$PROJECT_ROOT/apps/gpt-console/run.sh"' "$INSTALLER"
grep -Fq 'gpt-console) source_file="$GPT_CONSOLE_SOURCE" ;;' "$INSTALLER"
grep -Fq 'command -v gpt-console' "$INSTALLER"
printf 'OK: gpt-console integrado ao instalador global\n'
