#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
LOGGING="$ROOT/scripts/dev-manager/20-status-logging.sh"
for context in download_done file_inserted file_changed file_removed ddl_zip warning; do grep -Fq "$context) printf '$context'" "$LOGGING"; done
for icon in download-done file-inserted file-changed file-removed ddl-zip warning; do [[ -f "$ROOT/apps/dev-status/linux/icons/dev-status-$icon.svg" ]]; done
for state in DownloadDone FileInserted FileChanged FileRemoved DdlZip Warning; do grep -Fq "StatusCode::$state" "$ROOT/apps/dev-status/linux/src/main.cpp"; grep -Fq "StatusCode::$state" "$ROOT/apps/dev-status/src/main.cpp"; done
echo 'OK: taskbar reflete os contextos coloridos com estado/letra próprios.'
