#!/usr/bin/env bash
# Abre somente o projeto dev-automation no PhpStorm.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
TEMP_CONFIG="$(mktemp)"
cleanup() { rm -f "$TEMP_CONFIG"; }
trap cleanup EXIT

printf '%s\n' 'bots/dev-automation' > "$TEMP_CONFIG"

PHPSTORMS_PROJECTS_FILE="$TEMP_CONFIG" \
PHPSTORMS_INCLUDE_DEV_AUTOMATION=1 \
  "$SCRIPT_DIR/phpstorms.sh"
