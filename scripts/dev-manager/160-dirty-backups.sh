#!/usr/bin/env bash
# Contexto: proprietário de evento, debounce e backups inteligentes pendentes

event_owner_project() {
  local event_path="$1"
  local project project_dir parent_config_dir
  local best=""
  local best_len=-1

  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    target_is_aggregate "$project" && continue
    project_dir="$(project_path "$project")"

    if [ "$event_path" = "$project_dir" ] || [[ "$event_path" == "$project_dir/"* ]]; then
      if [ "${#project_dir}" -gt "$best_len" ]; then
        best="$project"
        best_len="${#project_dir}"
      fi
    fi

    # .config/<filho>/ fica fisicamente dentro do pai, mas é propriedade do
    # subprojeto. O prefixo é mais específico que a raiz do pai e portanto vence.
    parent_config_dir="$(project_parent_config_path "$project")"
    if [ -n "$parent_config_dir" ] && { [ "$event_path" = "$parent_config_dir" ] || [[ "$event_path" == "$parent_config_dir/"* ]]; }; then
      if [ "${#parent_config_dir}" -gt "$best_len" ]; then
        best="$project"
        best_len="${#parent_config_dir}"
      fi
    fi
  done < <(backup_targets)

  printf '%s\n' "$best"
}

mark_backup_dirty() {
  local project="$1"
  local event_path="${2:-}"

  [ -n "$project" ] || return 0
  if ! target_is_code_aggregate "$project" && [ ! -d "$(project_path "$project")" ]; then
    LOG_CONTEXT=error log "ERRO: alteração associada a projeto ausente; ignorando backup: $(project_path "$project")"
    unset 'DIRTY_BACKUP_TARGETS[$project]' 2>/dev/null || true
    return 0
  fi
  if [ -z "${DIRTY_BACKUP_TARGETS[$project]+x}" ]; then
    LOG_CONTEXT=backup log "Alteração detectada; backup pendente: $project"
  fi
  DIRTY_BACKUP_TARGETS["$project"]=1
  LAST_SOURCE_CHANGE="$(date +%s)"

  if [ "$event_path" = "$PROJECTS_FILE" ] || [ "$event_path" = "$IGNORE_ZIP_FILE" ]; then
    WATCH_RELOAD_REQUESTED=true
  fi
}

dirty_backup_count() {
  printf '%s\n' "${#DIRTY_BACKUP_TARGETS[@]}"
}

aggregate_depends_on_project() {
  local aggregate="$1"
  local project="$2"
  local aggregate_rel project_rel

  target_is_aggregate "$aggregate" || return 1
  target_is_code_aggregate "$aggregate" && return 0

  aggregate_rel="$(target_source_rel "$aggregate")"
  project_rel="$(target_source_rel "$project")"
  path_is_descendant "$project_rel" "$aggregate_rel"
}

backup_dirty_targets() {
  local project aggregate target
  local failed=0
  local -a dirty_projects=()
  local -a ordered=()
  declare -A selected_aggregates=()

  [ "${#DIRTY_BACKUP_TARGETS[@]}" -gt 0 ] || return 0

  if ! validate_backup_ignore_zip; then
    log "ERRO: backup inteligente cancelado antes de qualquer compactação."
    return 1
  fi

  # Preserva a ordem declarada no .projects para os projetos normais.
  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    target_is_aggregate "$project" && continue
    [ -n "${DIRTY_BACKUP_TARGETS[$project]+x}" ] || continue
    if [ ! -d "$(project_path "$project")" ]; then
      LOG_CONTEXT=error log "ERRO: projeto pendente não existe; removendo pendência de backup: $(project_path "$project")"
      unset 'DIRTY_BACKUP_TARGETS[$project]'
      continue
    fi
    dirty_projects+=("$project")
  done < <(backup_targets)

  [ "${#dirty_projects[@]}" -gt 0 ] || {
    DIRTY_BACKUP_TARGETS=()
    return 0
  }

  for project in "${dirty_projects[@]}"; do
    wait_if_paused
    if [ "$(project_path "$project")" = "$PROJECT_ROOT" ]; then
      if ! bump_dev_automation_build_version; then
        LOG_CONTEXT=error log "ERRO: não foi possível atualizar a versão do Dev Automation; backup cancelado."
        failed=1
        break
      fi
    fi
    if ! backup_project "$project"; then
      failed=1
    fi
  done

  # Nunca reconstrói agregadores a partir de um filho cujo backup falhou.
  if [ "$failed" -ne 0 ]; then
    log "ERRO: projeto alterado falhou; agregadores dependentes não foram atualizados."
    return 1
  fi

  while IFS= read -r aggregate || [ -n "$aggregate" ]; do
    [ -n "$aggregate" ] || continue
    target_is_aggregate "$aggregate" || continue
    for project in "${dirty_projects[@]}"; do
      if aggregate_depends_on_project "$aggregate" "$project"; then
        selected_aggregates["$aggregate"]=1
        break
      fi
    done
  done < <(backup_targets)

  mapfile -t ordered < <(backup_order_targets)
  for target in "${ordered[@]}"; do
    target_is_aggregate "$target" || continue
    [ -n "${selected_aggregates[$target]+x}" ] || continue
    wait_if_paused
    if ! backup_project "$target"; then
      failed=1
      break
    fi
  done

  if [ "$failed" -ne 0 ]; then
    log "ERRO: agregador dependente falhou; projeto permanece marcado para nova tentativa."
    return 1
  fi

  for project in "${dirty_projects[@]}"; do
    unset 'DIRTY_BACKUP_TARGETS[$project]'
  done

  LAST_SOURCE_CHANGE=0
  log "Backup inteligente concluído: ${#dirty_projects[@]} projeto(s) alterado(s) e somente agregadores dependentes."
  return 0
}

