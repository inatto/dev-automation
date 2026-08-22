#!/usr/bin/env bash
set -u

STATUS_FILE="${1:?status file ausente}"
LOG_FILE="${2:?log file ausente}"
PROJECT_NAME="${3:?projeto ausente}"
shift 3

mkdir -p "$(dirname "$STATUS_FILE")" "$(dirname "$LOG_FILE")"
printf 'STARTING\n' > "$STATUS_FILE"

on_stop() {
  printf 'STOPPED\n' > "$STATUS_FILE"
  exit 0
}
trap on_stop TERM INT HUP

set +e
"$@" >> "$LOG_FILE" 2>&1
status=$?
set -e

if ((status == 0)); then
  printf 'OK\n' > "$STATUS_FILE"
else
  printf 'ERRO:%d\n' "$status" > "$STATUS_FILE"
fi
exit "$status"
