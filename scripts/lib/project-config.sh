#!/usr/bin/env bash
# Resolve a lista de projetos específica desta instalação Linux/WSL.
# Identidade automática: /etc/machine-id. Override DEV_MACHINE_ID existe para testes/diagnóstico.

_dev_machine_id() {
  local value="${DEV_MACHINE_ID:-}"
  if [[ -z "$value" && -r /etc/machine-id ]]; then
    IFS= read -r value < /etc/machine-id || true
  fi
  value="${value//[[:space:]]/}"
  [[ "$value" =~ ^[0-9A-Fa-f]{32}$ ]] || return 1
  printf '%s\n' "${value,,}"
}

dev_projects_file() {
  local root="$1" machine_id machine_file default_file legacy_file
  default_file="$root/config/projects/default.projects"
  legacy_file="$root/config/auto-code-manager.projects"

  if machine_id="$(_dev_machine_id)"; then
    machine_file="$root/config/projects/$machine_id.projects"
    if [[ -f "$machine_file" ]]; then
      printf '%s\n' "$machine_file"
      return 0
    fi
  fi

  if [[ -f "$default_file" ]]; then
    printf '%s\n' "$default_file"
  else
    printf '%s\n' "$legacy_file"
  fi
}
