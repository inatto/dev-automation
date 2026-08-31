#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="$ROOT/apps/amazon-imap-bot"

[[ -x "$APP/run.sh" ]]
[[ -x "$APP/terminal/run.sh" ]]
[[ -d "$APP/flutter" ]]
[[ -d "$APP/api" ]]

grep -Fq 'AMAZON_IMAP_BOT_TERMINAL_SOURCE="$AMAZON_IMAP_BOT_DIR/terminal/run.sh"' \
  "$ROOT/deploy/local/install-commands.sh"
grep -Fq 'watch_dir="$AMAZON_IMAP_BOT_DIR"' \
  "$ROOT/deploy/local/install-commands.sh"

printf 'OK: Amazon IMAP Bot separa Terminal, Flutter e API e mantém launcher compatível\n'
