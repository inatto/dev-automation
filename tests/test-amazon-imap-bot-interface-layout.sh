#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="$ROOT/apps/amazon-imap-bot"

[[ -x "$APP/run.sh" ]]
[[ -x "$APP/terminal/run.sh" ]]
[[ -x "$APP/deploy/local/start.sh" ]]
[[ -d "$APP/flutter" ]]
[[ -d "$APP/api" ]]

grep -Fq 'AMAZON_IMAP_BOT_SOURCE="$AMAZON_IMAP_BOT_DIR/deploy/local/start.sh"' \
  "$ROOT/deploy/local/install-commands.sh"
! grep -Fq 'AMAZON_IMAP_BOT_TERMINAL_SOURCE=' "$ROOT/deploy/local/install-commands.sh"
! grep -Fq 'AMAZON_IMAP_BOT_LEGACY_SOURCE=' "$ROOT/deploy/local/install-commands.sh"
grep -Fq 'watch_dir="$AMAZON_IMAP_BOT_DIR"' \
  "$ROOT/deploy/local/install-commands.sh"

printf 'OK: comando global amazon-imap-bot é gerido pelo Dev Automation e inicia deploy/local/start.sh\n'
