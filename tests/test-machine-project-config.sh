#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/config/projects"
printf 'default/project\n' > "$TMP/config/projects/default.projects"
MACHINE_ID='11111111111111111111111111111111'
# shellcheck source=../scripts/lib/project-config.sh
source "$ROOT/scripts/lib/project-config.sh"
resolved="$(DEV_MACHINE_ID="$MACHINE_ID" dev_projects_file "$TMP")"
[[ "$resolved" == "$TMP/config/projects/$MACHINE_ID.projects" ]]
[[ -f "$resolved" ]]
[[ "$(cat "$resolved")" == 'default/project' ]]
printf 'machine/project\n' > "$TMP/config/projects/$MACHINE_ID.projects"
resolved="$(DEV_MACHINE_ID="$MACHINE_ID" dev_projects_file "$TMP")"
[[ "$resolved" == "$TMP/config/projects/$MACHINE_ID.projects" ]]
[[ "$(cat "$resolved")" == 'machine/project' ]]
DEV_MACHINE_ID="$MACHINE_ID" PROJECTS_FILE="$TMP/explicit.projects" bash -c 'source "$1/scripts/lib/project-config.sh"; printf "%s\n" "${PROJECTS_FILE:-$(dev_projects_file "$2")}"' _ "$ROOT" "$TMP" > "$TMP/out"
[[ "$(cat "$TMP/out")" == "$TMP/explicit.projects" ]]
echo 'OK: lista de projetos cria/resolve por machine-id e preserva override explícito.'
