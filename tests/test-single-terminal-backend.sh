#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TERMINALS="$ROOT/scripts/terminals/terminals.sh"
INSTALLER="$ROOT/deploy/local/install-commands.sh"

grep -Fq "printf 'gnome-terminal\\t%s\\n'" "$TERMINALS"
! grep -Fq 'TERMINALS_ALLOW_PTYXIS_FALLBACK' "$TERMINALS"
! grep -Fq "printf 'ptyxis\\t%s\\n'" "$TERMINALS"
! grep -Fq "printf 'kgx\\t%s\\n'" "$TERMINALS"
grep -Fq 'normalize_ubuntu_terminal' "$INSTALLER"
grep -Fq 'sudo apt-get install -y gnome-terminal' "$INSTALLER"
grep -Fq 'sudo apt-get purge -y ptyxis' "$INSTALLER"

echo 'OK: Dev Automation usa somente GNOME Terminal e remove Ptyxis duplicado.'
