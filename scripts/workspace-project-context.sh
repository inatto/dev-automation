#!/usr/bin/env bash
# Contexto compartilhado entre comandos que percorrem os workspaces dos projetos.
# Workspace 1 = LAZER; projetos começam no workspace 2, na ordem do registry.

WORKSPACE_CONTEXT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WORKSPACE_CONTEXT_ROOT="$(cd -- "$WORKSPACE_CONTEXT_DIR/.." && pwd -P)"
PROJECTS_FILE="${PROJECTS_FILE:-$WORKSPACE_CONTEXT_ROOT/config/auto-code-manager.projects}"
SERVICES_FILE="${SERVICES_FILE:-$WORKSPACE_CONTEXT_ROOT/config/services.csv}"

declare -ag WORKSPACE_PROJECTS=()
declare -Ag WORKSPACE_SERVICE_URLS=()

workspace_context_load_projects() {
  local raw line
  WORKSPACE_PROJECTS=()
  [[ -f "$PROJECTS_FILE" ]] || return 1
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#./}"
    line="${line%/}"
    [[ -n "$line" && "${line,,}" != *.zip ]] || continue
    WORKSPACE_PROJECTS+=("$line")
  done < "$PROJECTS_FILE"
}

workspace_context_load_services() {
  local application type web_port api_port host path url current
  WORKSPACE_SERVICE_URLS=()
  [[ -f "$SERVICES_FILE" ]] || return 1
  while IFS=';' read -r application type web_port api_port host path || [[ -n "${application:-}" ]]; do
    application="${application%$'\r'}"
    [[ -n "$application" && "$application" != application ]] || continue
    [[ -n "$host" ]] || continue
    path="${path:-/}"
    [[ "$path" == /* ]] || path="/$path"
    url="https://$host$path"
    current="${WORKSPACE_SERVICE_URLS[$application]:-}"
    if [[ -n "$current" ]]; then
      WORKSPACE_SERVICE_URLS[$application]="$current"$'\n'"$url"
    else
      WORKSPACE_SERVICE_URLS[$application]="$url"
    fi
  done < "$SERVICES_FILE"
}

workspace_context_service_key_for_project() {
  local entry="$1"
  case "$entry" in
    orgs/inst-app) printf 'site-inst\n' ;;
    infra/amazon-infra/apps/monitor-app) printf 'amazon-infra-monitor\n' ;;
    *) basename -- "$entry" ;;
  esac
}

workspace_context_project_for_workspace() {
  local workspace="$1" index
  [[ "$workspace" =~ ^[1-9][0-9]*$ ]] || return 2
  index=$((workspace - 2))
  (( index >= 0 && index < ${#WORKSPACE_PROJECTS[@]} )) || return 1
  printf '%s\n' "${WORKSPACE_PROJECTS[$index]}"
}

workspace_context_urls_for_project() {
  local entry="$1" key
  key="$(workspace_context_service_key_for_project "$entry")"
  [[ -n "${WORKSPACE_SERVICE_URLS[$key]:-}" ]] || return 1
  printf '%s\n' "${WORKSPACE_SERVICE_URLS[$key]}"
}

workspace_context_urls_for_workspace() {
  local workspace="$1" entry
  entry="$(workspace_context_project_for_workspace "$workspace")" || return 1
  workspace_context_urls_for_project "$entry"
}
