#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
RUNTIME="$ROOT/scripts/dev-manager/00-runtime.sh"
FILTERS="$ROOT/scripts/dev-manager/80-backup-filters.sh"
FILES="$ROOT/scripts/dev-manager/40-files-safety.sh"
MAIN="$ROOT/scripts/dev-manager/900-main.sh"
EVENTS="$ROOT/scripts/dev-manager/170-inotify-runtime.sh"
CLEANER="$ROOT/scripts/auto-clean-root.sh"

# Compatibilidade foi preservada, mas só roda em WSL/Windows.
grep -Fq 'is_wsl_runtime()' "$RUNTIME"
grep -Fq 'is_wsl_runtime || return 0' "$FILTERS"
grep -Fq 'clean_download_zone_identifiers()' "$FILES"
grep -Fq 'clean_windows_download_zone_identifiers()' "$FILES"
grep -Fq 'delete_zone_identifiers_in_dir "$CODE_ROOT" recursive' "$FILTERS"
grep -Fq 'done < <(download_inbox_existing_dirs)' "$FILTERS"
grep -Fq 'if is_wsl_runtime; then' "$MAIN"
grep -Fq 'clean_windows_download_zone_identifiers' "$MAIN"
grep -Fq 'if is_wsl_runtime && [[ "$event_path" == *":Zone.Identifier" ]]' "$EVENTS"
grep -Fq 'Linux nativo detectado: limpeza Zone.Identifier não é necessária.' "$CLEANER"

# Filtro de backup continua excluindo sidecars caso apareçam por cópia externa.
grep -Fq 'echo "- *:Zone.Identifier"' "$FILTERS"
grep -Fq 'echo "- **/*:Zone.Identifier"' "$FILTERS"

printf 'OK: Zone.Identifier é limpo nas áreas conhecidas no WSL, inclusive Downloads Windows; Linux nativo não varre\n'
