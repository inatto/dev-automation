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
  local root="$1" machine_id machine_file default_file tmp
  default_file="$root/config/projects/default.projects"

  if machine_id="$(_dev_machine_id)"; then
    machine_file="$root/config/projects/$machine_id.projects"
    if [[ ! -f "$machine_file" ]]; then
      [[ -f "$default_file" ]] || return 1
      mkdir -p -- "$(dirname -- "$machine_file")" || return 1
      tmp="$machine_file.tmp.$$"
      cp -- "$default_file" "$tmp" || { rm -f -- "$tmp"; return 1; }
      mv -- "$tmp" "$machine_file" || { rm -f -- "$tmp"; return 1; }
    fi
    printf '%s\n' "$machine_file"
    return 0
  fi

  [[ -f "$default_file" ]] || return 1
  printf '%s\n' "$default_file"
}
