#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
CODE_ROOT="$(dirname -- "$ROOT")"
PARENT="$(basename -- "$ROOT")"
CHILD="$PARENT/apps/gpt-console"
TEMP_OTHER="$(mktemp -d "$CODE_ROOT/dev-manager-restart-other-XXXXXX")"
OTHER="$(basename -- "$TEMP_OTHER")"

cleanup() {
  rm -rf -- "$TEMP_OTHER"
}
trap cleanup EXIT

PROJECT_ROOT="$ROOT"
DEV_MANAGER_PROJECTS_FILE=/dev/null
source "$ROOT/scripts/dev-manager/00-runtime.sh"
source "$ROOT/scripts/dev-manager/50-project-registry.sh"
source "$ROOT/scripts/dev-manager/60-project-runtime.sh"

log() { :; }

project_affects_dev_manager "$PARENT"
project_affects_dev_manager "$CHILD"
if project_affects_dev_manager "$OTHER"; then
  printf 'FALHOU: projeto fora do Dev Automation foi considerado parte do ecossistema\n' >&2
  exit 1
fi

MONITOR_LOCK_OWNED=true
DEV_MANAGER_RESTART_REQUESTED=false
request_dev_manager_restart_after_import "$PARENT"
[ "$DEV_MANAGER_RESTART_REQUESTED" = true ]

DEV_MANAGER_RESTART_REQUESTED=false
request_dev_manager_restart_after_import "$CHILD"
[ "$DEV_MANAGER_RESTART_REQUESTED" = true ]

DEV_MANAGER_RESTART_REQUESTED=false
request_dev_manager_restart_after_import "$OTHER"
[ "$DEV_MANAGER_RESTART_REQUESTED" = false ]

MONITOR_LOCK_OWNED=false
request_dev_manager_restart_after_import "$PARENT"
[ "$DEV_MANAGER_RESTART_REQUESTED" = false ]

printf 'OK: ZIP do Dev Automation pai/filho agenda reinício somente no monitor ativo\n'
