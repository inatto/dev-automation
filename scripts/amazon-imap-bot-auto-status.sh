#!/usr/bin/env bash
# Consulta objetiva para o Amazon IMAP Bot sobre supervisores AUTO de projetos.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=lib/project-config.sh
source "$SCRIPT_DIR/lib/project-config.sh"

STATE_DIR="${AUTO_CODE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dev-automation}"
RUNNING_PROJECTS_DIR="$STATE_DIR/running-projects"
CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
PROJECTS_FILE="${PROJECTS_FILE:-$(dev_projects_file "$PROJECT_ROOT")}"
QUERY="${*:-}"

fail() {
  printf '[amazon-imap-bot-auto-status] ERRO: %s\n' "$*" >&2
  exit 2
}

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

normalize_name() {
  local value
  value="$(trim "${1:-}")"
  value="${value,,}"
  value="${value//_/-}"
  value="${value// /-}"
  while [[ "$value" == *--* ]]; do value="${value//--/-}"; done
  printf '%s\n' "${value#remote-}"
}

project_label() {
  local base="${1##*/}" word label=""
  base="${base//-/ }"
  for word in $base; do
    label+="${word^} "
  done
  printf '%s\n' "${label% }"
}

resolve_project() {
  local wanted line base
  wanted="$(normalize_name "$QUERY")"
  [[ -n "$wanted" ]] || fail "informe o projeto (exemplo: Orbital Legal)"
  [[ -f "$PROJECTS_FILE" ]] || fail "arquivo de projetos não encontrado: $PROJECTS_FILE"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line%$'\r'}"
    line="$(trim "$line")"
    [[ -n "$line" && "${line,,}" != *.zip ]] || continue
    base="${line##*/}"
    if [[ "$(normalize_name "$line")" == "$wanted" \
       || "$(normalize_name "$base")" == "$wanted" ]]; then
      PROJECT_REL="$line"
      PROJECT_DIR="$CODE_ROOT/$line"
      PROJECT_LABEL="$(project_label "$base")"
      return 0
    fi
  done < "$PROJECTS_FILE"

  fail "projeto não encontrado na configuração ativa: $QUERY"
}

state_field() {
  local file="$1" key="$2"
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n 1
}

auto_running() {
  local mode="$1" file pid file_pid state_project state_mode auto_mode cmdline cwd
  [[ -d "$RUNNING_PROJECTS_DIR" ]] || return 1

  while IFS= read -r -d '' file; do
    pid="$(state_field "$file" PID)"
    state_project="$(state_field "$file" PROJECT_DIR)"
    state_mode="$(state_field "$file" DEPLOY_MODE)"
    auto_mode="$(state_field "$file" AUTO_MODE)"

    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    file_pid="${file##*/}"
    file_pid="${file_pid%.state}"
    [[ "$file_pid" == "$pid" ]] || continue
    [[ "$state_project" == "$PROJECT_DIR" ]] || continue
    [[ "$state_mode" == "$mode" && "$auto_mode" == "1" ]] || continue
    kill -0 "$pid" 2>/dev/null || continue

    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    [[ "$cmdline" == *project-command.sh* ]] || continue
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    [[ "$cwd" == "$(readlink -f "$PROJECT_DIR" 2>/dev/null || true)" ]] || continue
    return 0
  done < <(find "$RUNNING_PROJECTS_DIR" -maxdepth 1 -type f -name '*.state' -print0 2>/dev/null)

  return 1
}

resolve_project

local_status="NÃO RODANDO"
remote_status="NÃO RODANDO"
auto_running local && local_status="RODANDO"
auto_running remote && remote_status="RODANDO"

printf '%s AUTO local: %s\n' "$PROJECT_LABEL" "$local_status"
printf '%s AUTO remoto: %s\n' "$PROJECT_LABEL" "$remote_status"
