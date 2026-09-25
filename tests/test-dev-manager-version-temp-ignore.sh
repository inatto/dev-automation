#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="$ROOT/scripts/dev-manager/170-inotify-runtime.sh"
LIGHT="$ROOT/scripts/dev-manager/140-light-monitor.sh"
IGNORE="$ROOT/config/auto-code-manager.ignore-zip"

grep -Fq '[[ "$event_path" == "$PROJECT_ROOT/.VERSION-"* ]]' "$RUNTIME" || {
  echo 'FALHOU: inotify não ignora temporário .VERSION-*' >&2; exit 1;
}
grep -Fq "os.path.basename(abs_full).startswith('.VERSION-')" "$LIGHT" || {
  echo 'FALHOU: monitor leve não ignora temporário .VERSION-*' >&2; exit 1;
}
grep -Fxq '.VERSION-*' "$IGNORE" || {
  echo 'FALHOU: ignore-zip não contém .VERSION-*' >&2; exit 1;
}

echo 'OK: VERSION e .VERSION-* não retroalimentam backup'
