#!/usr/bin/env bash
# Funções compartilhadas para nomes lógicos e comandos globais de projetos.

project_configured_normal_paths() {
  local projects_file="$1"
  local raw_line line

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="${raw_line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    line="${line#./}"
    line="${line%/}"
    [[ "${line,,}" == *.zip ]] && continue
    printf '%s\n' "$line"
  done < "$projects_file"
}

project_logical_key() {
  local project_path="${1#./}"
  project_path="${project_path%/}"
  basename -- "$project_path"
}

project_registered_parent_path() {
  local project_path="${1#./}"
  local projects_file="$2"
  local candidate best="" best_len=-1

  project_path="${project_path%/}"

  while IFS= read -r candidate || [[ -n "$candidate" ]]; do
    [[ -n "$candidate" ]] || continue
    [[ "$candidate" != "$project_path" ]] || continue
    [[ "$project_path" == "$candidate/"* ]] || continue

    if (( ${#candidate} > best_len )); then
      best="$candidate"
      best_len=${#candidate}
    fi
  done < <(project_configured_normal_paths "$projects_file")

  printf '%s\n' "$best"
}

project_global_command_base() {
  local project_path="${1#./}"
  local projects_file="$2"
  local logical_name parent_path parent_name

  project_path="${project_path%/}"
  logical_name="$(project_logical_key "$project_path")"
  parent_path="$(project_registered_parent_path "$project_path" "$projects_file")"

  if [[ -n "$parent_path" ]]; then
    parent_name="$(project_logical_key "$parent_path")"
    printf '%s--%s\n' "$parent_name" "$logical_name"
  else
    printf '%s\n' "$logical_name"
  fi
}

validate_project_global_names() {
  local projects_file="$1"
  local project logical_key logical_lower command_base command_lower owner
  local failed=0
  declare -A logical_owners=()
  declare -A command_owners=()

  while IFS= read -r project || [[ -n "$project" ]]; do
    [[ -n "$project" ]] || continue

    logical_key="$(project_logical_key "$project")"
    logical_lower="${logical_key,,}"
    owner="${logical_owners[$logical_lower]:-}"
    if [[ -n "$owner" && "$owner" != "$project" ]]; then
      printf '[project-commands] ERRO: nome lógico de projeto duplicado %q.\n' "$logical_key" >&2
      printf '[project-commands]   Já cadastrado: %s\n' "$owner" >&2
      printf '[project-commands]   Duplicado:     %s\n' "$project" >&2
      failed=1
    else
      logical_owners["$logical_lower"]="$project"
    fi

    command_base="$(project_global_command_base "$project" "$projects_file")"
    command_lower="${command_base,,}"
    owner="${command_owners[$command_lower]:-}"
    if [[ -n "$owner" && "$owner" != "$project" ]]; then
      printf '[project-commands] ERRO: nome de comando global ambíguo %q.\n' "$command_base" >&2
      printf '[project-commands]   Já cadastrado: %s\n' "$owner" >&2
      printf '[project-commands]   Duplicado:     %s\n' "$project" >&2
      failed=1
    else
      command_owners["$command_lower"]="$project"
    fi
  done < <(project_configured_normal_paths "$projects_file")

  [[ "$failed" -eq 0 ]]
}
