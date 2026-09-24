#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP="$(mktemp -d /tmp/auto-code-version-loop-XXXXXX)"
PROJECT="$TEMP/dev-automation"
EVENTS="$TEMP/events.log"
WATCH_PID=""

cleanup() {
  if [ -n "$WATCH_PID" ] && kill -0 "$WATCH_PID" 2>/dev/null; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  rm -rf -- "$TEMP"
}
trap cleanup EXIT

mkdir -p "$PROJECT"
printf '2026.09.24-00.00-v1\n' > "$PROJECT/VERSION"

# 1) O incremento de versão não pode criar arquivo temporário dentro da pasta
# monitorada. Isso elimina a origem do autoevento que gerava o loop infinito.
if command -v inotifywait >/dev/null 2>&1; then
  inotifywait -m -q -e close_write -e create -e delete -e move -e attrib \
    --format $'%e\t%w%f' "$PROJECT" >"$EVENTS" 2>/dev/null &
  WATCH_PID=$!
  sleep 0.15
fi

PROJECT_ROOT="$PROJECT"
SCRIPT_VERSION="$(cat "$PROJECT/VERSION")"
log() { :; }
# shellcheck source=../scripts/dev-manager/130-backups.sh
source "$ROOT/scripts/dev-manager/130-backups.sh"
old_version="$SCRIPT_VERSION"
bump_dev_automation_build_version
[ "$SCRIPT_VERSION" != "$old_version" ]
[ "$(cat "$PROJECT/VERSION")" = "$SCRIPT_VERSION" ]

if [ -n "$WATCH_PID" ]; then
  sleep 0.15
  kill "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  WATCH_PID=""
  if grep -Eq $'\t.*/\.VERSION-[^/]*$' "$EVENTS"; then
    printf 'FALHOU: bump de VERSION criou temporário dentro da pasta monitorada\n' >&2
    cat "$EVENTS" >&2
    exit 1
  fi
fi

# 2) Defesa adicional: mesmo um .VERSION-* legado/atrasado deve ser descartado
# pelo handler antes de marcar qualquer projeto como sujo.
DIRTY_CALLED=0
mark_backup_dirty() { DIRTY_CALLED=$((DIRTY_CALLED + 1)); }
# shellcheck source=../scripts/dev-manager/170-inotify-runtime.sh
source "$ROOT/scripts/dev-manager/170-inotify-runtime.sh"
handle_watch_event 'CREATE' "$PROJECT/.VERSION-legacy"
handle_watch_event 'CLOSE_WRITE,CLOSE' "$PROJECT/VERSION"
[ "$DIRTY_CALLED" -eq 0 ] || {
  printf 'FALHOU: VERSION/.VERSION-* gerado pelo manager voltou para a fila de backup\n' >&2
  exit 1
}

printf 'OK: VERSION não cria autoevento de backup e VERSION/.VERSION-* são ignorados pelo watcher\n'
