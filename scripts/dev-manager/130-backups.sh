#!/usr/bin/env bash
# Contexto: backup de projeto, limpeza e backup completo

backup_project() {
  local project="$1"
  local project_dir archive_name temp_dir temp_zip final_zip filter_file=""
  local child child_name child_zip child_count
  local sanitize_result sanitized_files sanitized_values
  local -a children=()

  project_dir="$(project_path "$project")"
  archive_name="$(project_archive_name "$project")"

  if [ ! -d "$project_dir" ]; then
    log "ERRO: alvo não existe: $project_dir"
    rm -f -- "$(project_archive_path "$project")"
    return 1
  fi

  if ! target_is_aggregate "$project"; then
    # Segurança desacoplada: audita/aplica git-crypt antes do backup, mas nunca
    # derruba a esteira. Falha vira alerta crítico vermelho + som pelo módulo 190.
    gitcrypt_guard_project "$project" || true
  fi

  taskbar_status backup "$archive_name"
  temp_dir="$(mktemp -d "/tmp/auto-code-backup-${archive_name}-XXXXXX")"
  temp_zip="/tmp/${archive_name}-backup-$$.zip"
  final_zip="$(project_archive_path "$project")"

  log "Gerando backup: $project -> $final_zip"

  if target_is_aggregate "$project"; then
    mapfile -t children < <(aggregate_child_targets "$project")
    child_count="${#children[@]}"
    if [ "$child_count" -eq 0 ]; then
      log "ERRO: agregador sem filhos configurados: $project"
      rm -rf -- "$temp_dir" "$temp_zip"
      return 1
    fi

    for child in "${children[@]}"; do
      child_name="$(project_archive_name "$child")"
      child_zip="$(project_archive_path "$child")"
      if [ ! -s "$child_zip" ] || ! unzip -tq "$child_zip" >/dev/null 2>&1; then
        log "ERRO: ZIP filho ausente ou inválido para o agregador: $child_zip"
        rm -rf -- "$temp_dir" "$temp_zip"
        return 1
      fi
      cp -f -- "$child_zip" "$temp_dir/$child_name.zip" || {
        log "ERRO ao incluir ZIP filho no agregador: $child_zip"
        rm -rf -- "$temp_dir" "$temp_zip"
        return 1
      }
    done
    log "Agregador explícito preparado com $child_count ZIP(s), sem duplicar ramos cobertos."
  else
    filter_file="$(mktemp "/tmp/auto-code-filter-${archive_name}-XXXXXX")"
    make_project_rsync_filter \
      "$IGNORE_ZIP_FILE" \
      "$project_dir" \
      "auto-code-manager.ignore-zip" \
      "$filter_file"
    append_registered_subproject_excludes "$project" "$filter_file"

    # .remover é instrução transitória recebida em ZIP. Nunca volta para o
    # backup/cache do projeto, mesmo que uma regra específica tente incluí-la.
    {
      printf '%s\n' '- *.remover' '- **/*.remover' '- .dev-auto-removal-*' '- **/.dev-auto-removal-*'
      cat "$filter_file"
    } > "$filter_file.remover-tmp"
    mv -f -- "$filter_file.remover-tmp" "$filter_file"

    if ! rsync -a --filter="merge $filter_file" "$project_dir/" "$temp_dir/"; then
      log "ERRO no rsync do projeto: $project"
      rm -rf -- "$temp_dir" "$filter_file" "$temp_zip"
      return 1
    fi

    if ! sanitize_result="$(sanitize_backup_config_passwords "$temp_dir")"; then
      log "ERRO ao sanitizar senhas dos configs no backup: $project"
      rm -rf -- "$temp_dir" "$filter_file" "$temp_zip"
      return 1
    fi
    sanitized_files="${sanitize_result%%:*}"
    sanitized_values="${sanitize_result##*:}"
    if [ "${sanitized_values:-0}" -gt 0 ]; then
      log "Configs sanitizados no ZIP: ${sanitized_values} senha(s) em ${sanitized_files} arquivo(s)."
    fi

    if ! save_protected_config_baseline "$project" "$temp_dir"; then
      log "ERRO ao salvar referência sanitizada dos configs protegidos: $project"
      rm -rf -- "$temp_dir" "$filter_file" "$temp_zip"
      return 1
    fi
    log "Referência sanitizada dos configs protegidos atualizada."
  fi

  if ! (cd "$temp_dir" && zip -qry "$temp_zip" .); then
    log "ERRO ao compactar alvo: $project"
    rm -rf -- "$temp_dir" ${filter_file:+"$filter_file"} "$temp_zip"
    return 1
  fi
  if [ ! -s "$temp_zip" ] || ! unzip -tq "$temp_zip" >/dev/null 2>&1; then
    log "ERRO: validação do backup falhou: $project"
    rm -rf -- "$temp_dir" ${filter_file:+"$filter_file"} "$temp_zip"
    return 1
  fi

  mv -f -- "$temp_zip" "$final_zip"
  rm -rf -- "$temp_dir"
  [ -z "$filter_file" ] || rm -f -- "$filter_file"
  log "OK backup: $final_zip"
  return 0
}

clean_unmanaged_backup_zips() {
  # A saída agora é a própria pasta Code, que pode conter ZIPs manuais do
  # usuário. Nunca varremos/removemos ZIPs não gerenciados nessa pasta.
  return 0
}

backup_all() {
  local project
  local failed=0
  local -a projects=()

  if ! validate_backup_ignore_zip; then
    log "ERRO: rodada de backup cancelada antes de qualquer compactação."
    return 1
  fi

  mapfile -t projects < <(backup_order_targets)
  for project in "${projects[@]}"; do
    [ -n "$project" ] || continue

    # Um catálogo pode listar projetos que ainda não foram clonados/importados
    # nesta máquina. Isso é estado normal durante bootstrap: mantém o cadastro
    # para reconhecer futuros ZIPs, mas não derruba o manager por pasta ausente.
    if ! target_is_code_aggregate "$project" && [ ! -d "$(project_path "$project")" ]; then
      log "Ignorando backup; alvo configurado ainda não existe: $(project_path "$project")"
      continue
    fi

    wait_if_paused
    backup_project "$project" || failed=1
  done

  if [ "$failed" -ne 0 ]; then
    log "ERRO: um ou mais alvos configurados falharam nesta rodada."
    return 1
  fi

  log "Rodada completa: somente projetos/agregadores explicitamente presentes no .projects foram gerados."
  return 0
}


