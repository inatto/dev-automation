#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT/scripts/terminals/terminals.sh"
grep -Fq 'terminal_session_shell()' "$SCRIPT"
grep -Fq 'terminal mantido aberto' "$SCRIPT"
! grep -Fq 'exec $command_name' "$SCRIPT"
echo 'OK: launcher mantém shell após encerramento do comando.'
