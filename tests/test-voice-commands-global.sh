#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
INSTALLER="$ROOT/deploy/local/install-commands.sh"
APP="$ROOT/apps/voice-commands"

[[ -f "$APP/run.sh" ]]
grep -Fq 'VOICE_COMMANDS_SOURCE="$PROJECT_ROOT/apps/voice-commands/run.sh"' "$INSTALLER"
grep -Fq 'voice-commands) source_file="$VOICE_COMMANDS_SOURCE" ;;' "$INSTALLER"
grep -Fq 'command -v voice-commands' "$INSTALLER"
grep -Fq '%h/Code/bots/dev-automation/apps/voice-commands' "$APP/voice-commands.service"
grep -Fq '$HOME/Code/bots/dev-automation/apps/voice-commands' "$APP/install-service.sh"
printf 'OK voice-commands global\n'
