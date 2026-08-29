#!/usr/bin/env bash
# Contexto: alvos, projetos, agregadores, nomes e validação do catálogo

normalize_target() {
  local target="$1"
  # Arquivos de configuração podem vir do Windows. CRLF nunca pode virar
  # parte invisível do caminho no Linux.
  target="${target%$'\r'}"
  target="${target#./}"
  target="${target%/}"
  printf '%s\n' "$target"
}

target_is_aggregate() {
  local target
  target="$(normalize_target "$1")"
  [[ "${target,,}" == *.zip ]]
}

target_is_code_aggregate() {
  local target
  target="$(normalize_target "$1")"
  [[ "$target" != */* && "${target,,}" == "code.zip" ]]
}

target_source_rel() {
  local target
  target="$(normalize_target "$1")"

  if target_is_code_aggregate "$target"; then
    printf '\n'
  elif target_is_aggregate "$target"; then
    printf '%s\n' "${target:0:${#target}-4}"
  else
    printf '%s\n' "$target"
  fi
}

project_path() {
  local project="$1"
  local source_rel
  source_rel="$(target_source_rel "$project")"

  if [ -z "$source_rel" ]; then
    printf '%s\n' "$CODE_ROOT"
  else
    printf '%s/%s\n' "$CODE_ROOT" "$source_rel"
  fi
}

project_logical_name() {
  local project="$1"
  local source_rel

  source_rel="$(target_source_rel "$project")"
  [ -n "$source_rel" ] || return 1
  basename -- "$source_rel"
}

registered_parent_project() {
  local project="$1"
  local project_rel candidate candidate_rel
  local best=""
  local best_len=-1

  target_is_aggregate "$project" && return 0
  project_rel="$(target_source_rel "$project")"

  while IFS= read -r candidate || [ -n "$candidate" ]; do
    [ -n "$candidate" ] || continue
    [ "$candidate" != "$project" ] || continue
    target_is_aggregate "$candidate" && continue
    candidate_rel="$(target_source_rel "$candidate")"
    path_is_descendant "$project_rel" "$candidate_rel" || continue

    if [ "${#candidate_rel}" -gt "$best_len" ]; then
      best="$candidate"
      best_len="${#candidate_rel}"
    fi
  done < <(backup_targets)

  printf '%s\n' "$best"
}

project_archive_name() {
  local project="$1"
  local normalized logical_name parent parent_name

  normalized="$(normalize_target "$project")"
  if target_is_aggregate "$normalized"; then
    normalized="${normalized:0:${#normalized}-4}"
    basename -- "$normalized"
    return 0
  fi

  logical_name="$(project_logical_name "$normalized")"
  parent="$(registered_parent_project "$normalized")"
  if [ -n "$parent" ]; then
    parent_name="$(project_logical_name "$parent")"
    printf '%s-%s\n' "$parent_name" "$logical_name"
  else
    printf '%s\n' "$logical_name"
  fi
}

project_import_names() {
  local project="$1"
  local canonical logical parent parent_name legacy

  canonical="$(project_archive_name "$project")"
  printf '%s\n' "$canonical"

  if ! target_is_aggregate "$project"; then
    logical="$(project_logical_name "$project")"
    parent="$(registered_parent_project "$project")"
    legacy=""
    if [ -n "$parent" ]; then
      parent_name="$(project_logical_name "$parent")"
      legacy="$parent_name--$logical"
      if [ "${legacy,,}" != "${canonical,,}" ]; then
        printf '%s\n' "$legacy"
      fi
    fi

    if [ "${logical,,}" != "${canonical,,}" ] && [ "${logical,,}" != "${legacy,,}" ]; then
      printf '%s\n' "$logical"
    fi
  fi
}

project_archive_path() {
  local project="$1"
  local archive_name

  archive_name="$(project_archive_name "$project")"
  printf '%s/%s.zip\n' "$(archive_output_dir)" "$archive_name"
}

project_archive_content_prefix() {
  local project="$1"
  local normalized parent project_rel parent_rel

  normalized="$(normalize_target "$project")"
  target_is_aggregate "$normalized" && return 0

  parent="$(registered_parent_project "$normalized")"
  [ -n "$parent" ] || return 0

  project_rel="$(target_source_rel "$normalized")"
  parent_rel="$(target_source_rel "$parent")"
  printf '%s\n' "${project_rel#"$parent_rel/"}"
}

configured_projects() {
  clean_file "$PROJECTS_FILE"
}

backup_targets() {
  local project
  declare -A seen=()

  # A lista .projects é a única fonte da verdade. Nenhum agrupador é inferido.
  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    project="$(normalize_target "$project")"

    if [ -z "${seen[$project]+x}" ]; then
      printf '%s\n' "$project"
      seen["$project"]=1
    fi
  done < <(configured_projects)
}

path_is_descendant() {
  local child="$1"
  local parent="$2"

  [ -n "$child" ] || return 1
  if [ -z "$parent" ]; then
    return 0
  fi

  [[ "$child" == "$parent/"* ]]
}

aggregate_child_targets() {
  local aggregate="$1"
  local aggregate_rel target target_rel other other_rel covered
  local -a targets=()
  local -a aggregates=()

  aggregate_rel="$(target_source_rel "$aggregate")"
  mapfile -t targets < <(backup_targets)

  # Descendentes agregadores explícitos podem representar um ramo inteiro.
  for target in "${targets[@]}"; do
    [ "$target" != "$aggregate" ] || continue
    target_is_aggregate "$target" || continue
    target_is_code_aggregate "$target" && continue
    target_rel="$(target_source_rel "$target")"
    path_is_descendant "$target_rel" "$aggregate_rel" || continue
    aggregates+=("$target")
  done

  # Em ordem do .projects, seleciona apenas a representação mais alta de cada
  # ramo: agregador explícito cobre seus descendentes; projeto normal nunca
  # cobre subprojetos cadastrados, porque o ZIP dele os exclui fisicamente.
  for target in "${targets[@]}"; do
    [ "$target" != "$aggregate" ] || continue
    target_is_code_aggregate "$target" && continue
    target_rel="$(target_source_rel "$target")"
    path_is_descendant "$target_rel" "$aggregate_rel" || continue

    covered=false
    for other in "${aggregates[@]}"; do
      [ "$other" != "$target" ] || continue
      other_rel="$(target_source_rel "$other")"
      if path_is_descendant "$target_rel" "$other_rel"; then
        covered=true
        break
      fi
    done

    [ "$covered" = false ] || continue
    printf '%s\n' "$target"
  done
}

registered_subprojects() {
  local parent="$1"
  local parent_rel target target_rel

  parent_rel="$(target_source_rel "$parent")"
  while IFS= read -r target || [ -n "$target" ]; do
    [ -n "$target" ] || continue
    [ "$target" != "$parent" ] || continue
    target_is_aggregate "$target" && continue
    target_rel="$(target_source_rel "$target")"
    path_is_descendant "$target_rel" "$parent_rel" || continue
    printf '%s\n' "$target"
  done < <(backup_targets)
}

registered_subproject_relative_paths() {
  local parent="$1"
  local parent_rel child child_rel relative

  parent_rel="$(target_source_rel "$parent")"
  while IFS= read -r child || [ -n "$child" ]; do
    [ -n "$child" ] || continue
    child_rel="$(target_source_rel "$child")"
    relative="${child_rel#"$parent_rel/"}"
    [ -n "$relative" ] || continue
    printf '%s\n' "$relative"
  done < <(registered_subprojects "$parent")
}

project_relpath_belongs_to_registered_subproject() {
  local parent="$1"
  local rel="$2"
  local child_relative

  while IFS= read -r child_relative || [ -n "$child_relative" ]; do
    [ -n "$child_relative" ] || continue
    if [ "$rel" = "$child_relative" ] || [[ "$rel" == "$child_relative/"* ]]; then
      return 0
    fi
  done < <(registered_subproject_relative_paths "$parent")

  return 1
}

append_registered_subproject_excludes() {
  local parent="$1"
  local filter_file="$2"
  local phase="${3:-backup}"
  local relative
  local count=0

  while IFS= read -r relative || [ -n "$relative" ]; do
    [ -n "$relative" ] || continue
    printf -- '- /%s/***\n' "$relative" >> "$filter_file"
    count=$((count + 1))
    if [ "$phase" = "unzip" ]; then
      log "Protegendo subprojeto cadastrado durante unzip do pai: $relative/"
    else
      log "Excluindo subprojeto cadastrado do ZIP pai: $relative/"
    fi
  done < <(registered_subproject_relative_paths "$parent")

  if [ "$count" -gt 0 ]; then
    if [ "$phase" = "unzip" ]; then
      log "$count subprojeto(s) cadastrado(s) isolado(s) da importação do pai."
    else
      log "$count subprojeto(s) cadastrado(s) excluído(s) do backup pai."
    fi
  fi
}

backup_order_targets() {
  local target rel depth
  local -a normal=()
  local -a aggregate_lines=()
  local -a code=()

  while IFS= read -r target || [ -n "$target" ]; do
    [ -n "$target" ] || continue
    if ! target_is_aggregate "$target"; then
      normal+=("$target")
    elif target_is_code_aggregate "$target"; then
      code+=("$target")
    else
      rel="$(target_source_rel "$target")"
      depth="$(awk -F/ '{print NF}' <<<"$rel")"
      aggregate_lines+=("$depth"$'\t'"$target")
    fi
  done < <(backup_targets)

  [ "${#normal[@]}" -eq 0 ] || printf '%s\n' "${normal[@]}"
  if [ "${#aggregate_lines[@]}" -gt 0 ]; then
    printf '%s\n' "${aggregate_lines[@]}" | sort -t $'\t' -k1,1nr -k2,2 | cut -f2-
  fi
  [ "${#code[@]}" -eq 0 ] || printf '%s\n' "${code[@]}"
}

validate_projects() {
  local project project_dir archive_name source_rel logical_name alias alias_key owner
  local failed=0
  local -a aggregate_children=()
  declare -A logical_owner=()
  declare -A alias_owner=()

  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    project="$(normalize_target "$project")"

    if [[ "$project" = /* || "$project" = *".."* ]]; then
      log "ERRO: entrada inválida em $PROJECTS_FILE: $project"
      failed=1
      continue
    fi

    project_dir="$(project_path "$project")"
    archive_name="$(project_archive_name "$project")"
    source_rel="$(target_source_rel "$project")"

    if target_is_aggregate "$project"; then
      if ! target_is_code_aggregate "$project" && [ ! -d "$project_dir" ]; then
        log "ERRO: agregador configurado não existe; ignorando até aparecer: $project_dir"
      fi
      if [ -n "$source_rel" ]; then
        mapfile -t aggregate_children < <(aggregate_child_targets "$project")
        if [ "${#aggregate_children[@]}" -eq 0 ]; then
          log "ERRO: agregador sem projetos/agrupadores descendentes configurados: $project"
          failed=1
        fi
      fi
    else
      if [ ! -d "$project_dir" ]; then
        log "ERRO: projeto configurado não existe; ignorando até aparecer: $project_dir"
      fi

      logical_name="$(project_logical_name "$project")"
      alias_key="${logical_name,,}"
      owner="${logical_owner[$alias_key]:-}"
      if [ -n "$owner" ] && [ "$owner" != "$project" ]; then
        log "ERRO: nome lógico de projeto duplicado '$logical_name'."
        log "  Já cadastrado: $owner"
        log "  Duplicado:     $project"
        log "Nomes lógicos de projeto são chave única global, independentemente do projeto pai."
        failed=1
      else
        logical_owner["$alias_key"]="$project"
      fi
    fi

    while IFS= read -r alias || [ -n "$alias" ]; do
      [ -n "$alias" ] || continue
      alias_key="${alias,,}"
      owner="${alias_owner[$alias_key]:-}"
      if [ -n "$owner" ] && [ "$owner" != "$project" ]; then
        log "ERRO: alias de ZIP ambíguo '$alias.zip' entre '$owner' e '$project'."
        failed=1
      else
        alias_owner["$alias_key"]="$project"
      fi
    done < <(project_import_names "$project")
  done < <(backup_targets)

  [ "$failed" -eq 0 ]
}

