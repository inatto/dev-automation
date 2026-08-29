#!/usr/bin/env bash
# Contexto: importação transacional de ZIPs recebidos em ~/Downloads

import_one_zip() {
  local zip_file="$1"
  local skip_stable="${2:-false}"
  local zip_name project archive_name logical_name project_dir temp_dir source_dir filtered_dir unzip_filter_file removal_manifest content_prefix
  local total_files checked_files rel destination removal_count=0 runtime_scope="both"
  local nested_zip nested_project nested_count=0 nested_index expected child_name
  local -a nested_zips=() nested_projects=() expected_children=()
  local -A nested_seen=() expected_targets=()

  zip_name="$(basename "$zip_file")"
  project="$(project_for_zip "$zip_name")"

  if [ -z "$project" ]; then
    log "Ignorando ZIP sem projeto/agregador configurado: $zip_name"
    return 0
  fi

  if [ "$skip_stable" != "true" ] && ! stable_file "$zip_file"; then
    log "ZIP ainda está sendo gravado: $zip_name"
    return 0
  fi

  taskbar_status unzip "$zip_name"
  archive_name="$(project_archive_name "$project")"
  logical_name=""
  if ! target_is_aggregate "$project"; then
    logical_name="$(project_logical_name "$project")"
  fi
  project_dir="$(project_path "$project")"
  temp_dir="$(mktemp -d "/tmp/auto-code-import-${archive_name}-XXXXXX")"

  line
  log "IMPORTAÇÃO INICIADA"
  log "ZIP:        $zip_file"
  log "Alvo:       $project"
  log "Destino:    $project_dir"
  log "Temporário: $temp_dir"

  if ! unzip -tq "$zip_file" >/dev/null 2>&1; then
    log "ERRO: ZIP inválido ou corrompido. O ZIP foi mantido."
    rm -rf -- "$temp_dir"
    return 1
  fi
  if ! validate_zip_entries_safe "$zip_file"; then
    log "ERRO: ZIP contém caminho/tipo inseguro. O ZIP foi mantido."
    rm -rf -- "$temp_dir"
    return 1
  fi

  log "Extraindo ZIP para a pasta temporária; symlinks do ZIP serão ignorados..."
  if ! extract_zip_without_symlinks "$zip_file" "$temp_dir"; then
    log "ERRO: falha ao extrair. O ZIP foi mantido."
    rm -rf -- "$temp_dir"
    return 1
  fi
  if ! verify_zip_modes_after_extract "$zip_file" "$temp_dir"; then
    log "ERRO: chmod armazenado no ZIP não sobreviveu à extração. Projeto não foi alterado; ZIP mantido."
    rm -rf -- "$temp_dir"
    return 1
  fi

  content_prefix="$(project_archive_content_prefix "$project")"
  if [ -n "$content_prefix" ] && [ -d "$temp_dir/$content_prefix" ]; then
    source_dir="$temp_dir/$content_prefix"
    log "Hierarquia do subprojeto identificada no ZIP: $content_prefix/"
  elif [ -d "$temp_dir/$archive_name" ]; then
    source_dir="$temp_dir/$archive_name"
    log "Raiz do ZIP identificada: $archive_name/"
  elif [ -n "$logical_name" ] && [ -d "$temp_dir/$logical_name" ]; then
    source_dir="$temp_dir/$logical_name"
    log "Raiz lógica do projeto identificada: $logical_name/"
  else
    source_dir="$temp_dir"
    log "ZIP sem pasta raiz do alvo; usando a raiz do ZIP."
  fi

  if target_is_aggregate "$project"; then
    mapfile -t expected_children < <(aggregate_child_targets "$project")
    for expected in "${expected_children[@]}"; do
      expected_targets["$expected"]=1
    done

    while IFS= read -r -d '' nested_zip; do
      child_name="$(basename -- "$nested_zip")"
      nested_project="$(project_for_zip "$child_name")"

      if [ -z "$nested_project" ] || [ -z "${expected_targets[$nested_project]+x}" ]; then
        log "ERRO: ZIP agregador contém filho não esperado: $(basename -- "$nested_zip")"
        log "ZIP agregador mantido: $zip_file"
        rm -rf -- "$temp_dir"
        return 1
      fi
      if [ -n "${nested_seen[$nested_project]+x}" ]; then
        log "ERRO: ZIP agregador contém mais de um ZIP para o mesmo alvo: $nested_project"
        log "ZIP agregador mantido: $zip_file"
        rm -rf -- "$temp_dir"
        return 1
      fi
      if ! unzip -tq "$nested_zip" >/dev/null 2>&1; then
        log "ERRO: ZIP filho inválido: $(basename -- "$nested_zip")"
        log "Nenhum ZIP filho foi importado; ZIP agregador mantido: $zip_file"
        rm -rf -- "$temp_dir"
        return 1
      fi

      nested_seen["$nested_project"]=1
      nested_zips+=("$nested_zip")
      nested_projects+=("$nested_project")
    done < <(find "$source_dir" -maxdepth 1 -type f -iname "*.zip" -print0 2>/dev/null)

    for expected in "${expected_children[@]}"; do
      if [ -z "${nested_seen[$expected]+x}" ]; then
        log "ERRO: ZIP agregador não contém o filho esperado: $(project_archive_name "$expected").zip"
        log "ZIP agregador mantido: $zip_file"
        rm -rf -- "$temp_dir"
        return 1
      fi
    done

    if find "$source_dir" -maxdepth 1 -type f ! -iname '*.zip' -print -quit | grep -q .; then
      log "ERRO: ZIP agregador deve conter somente ZIPs filhos configurados."
      log "ZIP agregador mantido: $zip_file"
      rm -rf -- "$temp_dir"
      return 1
    fi

    nested_count="${#nested_zips[@]}"
    [ "$nested_count" -gt 0 ] || {
      log "ERRO: ZIP agregador vazio. O ZIP foi mantido."
      rm -rf -- "$temp_dir"
      return 1
    }

    log "Todos os $nested_count ZIP(s) filho(s) foram validados antes da importação."
    for ((nested_index = 0; nested_index < nested_count; nested_index++)); do
      nested_zip="${nested_zips[$nested_index]}"
      nested_project="${nested_projects[$nested_index]}"
      log "ZIP filho [$((nested_index + 1))/$nested_count]: $(basename -- "$nested_zip") -> $nested_project"
      if ! import_one_zip "$nested_zip" true; then
        log "ERRO: falha ao importar ZIP filho. O ZIP agregador foi mantido: $zip_file"
        rm -rf -- "$temp_dir"
        return 1
      fi
    done

    rm -rf -- "$temp_dir"
    if ! finalize_import_zip "$zip_file"; then
      log "ERRO: filhos importados, mas o ZIP agregador não pôde ser removido: $zip_file"
      return 1
    fi
    log "$nested_count ZIP(s) filho(s) importado(s) e confirmado(s)."
    log "IMPORTAÇÃO DE AGREGADOR CONCLUÍDA: $project"
    soft_beep
    line
    return 0
  fi

  [ -d "$project_dir" ] || {
    log "ERRO: projeto reconhecido, mas o diretório local não existe: $project_dir"
    log "ZIP mantido em Downloads."
    rm -rf -- "$temp_dir"
    return 1
  }

  # O modo POSIX armazenado no ZIP é a fonte de verdade da importação.
  # A extração segura já o reaplica no staging e verify_zip_modes_after_extract
  # confirma o round-trip antes de qualquer alteração no projeto.

  # O ZIP em /home/daniel/Code é o ponto de retorno imediatamente anterior à
  # importação. Só tocamos no projeto se esse backup pré-importação validar.
  log "Gerando backup pré-importação do estado atual..."
  if ! backup_project "$project"; then
    log "ERRO: backup pré-importação falhou. Projeto não foi alterado; ZIP mantido."
    rm -rf -- "$temp_dir"
    return 1
  fi

  filtered_dir="$(mktemp -d "/tmp/auto-code-unzip-filtered-${archive_name}-XXXXXX")"
  unzip_filter_file="$(mktemp "/tmp/auto-code-unzip-filter-${archive_name}-XXXXXX")"
  removal_manifest="$(mktemp "/tmp/auto-code-remover-${archive_name}-XXXXXX")"
  make_project_rsync_filter \
    "$IGNORE_UNZIP_FILE" \
    "$project_dir" \
    "auto-code-manager.ignore-unzip" \
    "$unzip_filter_file"

  # Config protegido nunca entra no rsync direto. Primeiro é reconciliado em
  # staging: ********/*** recupera o valor real local; valores não secretos podem mudar.
  {
    echo "- /config/local/***"
    echo "- **/config/local/***"
    echo "- /config/remote/***"
    echo "- **/config/remote/***"
    echo "- /config/production/***"
    echo "- **/config/production/***"
    echo "- /.config/***"
    echo "- **/.config/***"
  } >> "$unzip_filter_file"

  log "Protegendo no unzip: config/local, config/remote, config/production e .config entram somente por merge seguro."
  log "Aplicando regras de ignore-unzip..."
  if ! rsync -a --filter="merge $unzip_filter_file" -- "$source_dir/" "$filtered_dir/"; then
    log "ERRO: falha ao aplicar ignore-unzip. O ZIP foi mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file" "$removal_manifest"
    return 1
  fi

  # Se o destino local já possui symlink, esse caminho pertence à máquina.
  # Nada vindo do ZIP pode substituí-lo, atravessá-lo ou recriá-lo.
  preserve_destination_symlinks_from_staging "$project_dir" "$filtered_dir"

  if ! materialize_changed_protected_configs "$project" "$source_dir" "$filtered_dir"; then
    log "ERRO: merge seguro dos configs protegidos falhou. Projeto não recebeu o staging; ZIP mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file" "$removal_manifest"
    return 1
  fi

  removal_count="$(find "$filtered_dir" -type f -name '*.remover' -printf '.' 2>/dev/null | wc -c)"
  if ! prepare_removal_markers "$filtered_dir" "$project_dir" "$removal_manifest"; then
    log "ERRO: validação de .remover falhou. O ZIP foi mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file" "$removal_manifest"
    return 1
  fi
  [ "$removal_count" -eq 0 ] || log "Marcadores .remover validados: $removal_count; serão aplicados só após confirmar os arquivos novos."

  source_dir="$filtered_dir"
  total_files="$(find "$source_dir" -type f -printf '.' 2>/dev/null | wc -c)"
  if [ "$total_files" -eq 0 ] && [ "$removal_count" -eq 0 ]; then
    log "ERRO: nenhum arquivo nem marcador .remover foi extraído. O ZIP foi mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file" "$removal_manifest"
    return 1
  fi

  log "Arquivos diretos extraídos: $total_files"
  find "$source_dir" -type f -printf '  EXTRAÍDO: %P\n'

  log "Copiando arquivos diretos para o destino..."
  if ! rsync -a --checksum --delay-updates --itemize-changes -- "$source_dir/" "$project_dir/" | sed 's/^/  RSYNC: /'; then
    log "ERRO: falha ao copiar. O ZIP foi mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file" "$removal_manifest"
    return 1
  fi

  log "Conferindo arquivo por arquivo no destino..."
  checked_files=0
  while IFS= read -r -d '' rel; do
    destination="$project_dir/$rel"
    if [ ! -f "$destination" ]; then
      log "ERRO: arquivo não apareceu no destino: $destination"
      log "ZIP mantido: $zip_file"
      rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file" "$removal_manifest"
      return 1
    fi
    if ! cmp -s -- "$source_dir/$rel" "$destination"; then
      log "ERRO: arquivo no destino está diferente: $destination"
      log "ZIP mantido: $zip_file"
      rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file" "$removal_manifest"
      return 1
    fi
    checked_files=$((checked_files + 1))
    log "CONFIRMADO [$checked_files/$total_files]: $destination"
  done < <(find "$source_dir" -type f -printf '%P\0')

  if [ "$checked_files" -ne "$total_files" ]; then
    log "ERRO: conferidos $checked_files de $total_files arquivos. ZIP mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file" "$removal_manifest"
    return 1
  fi

  if ! apply_removal_manifest "$project_dir" "$removal_manifest"; then
    log "ERRO: falha ao aplicar .remover; ZIP mantido para nova tentativa."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file" "$removal_manifest"
    return 1
  fi

  runtime_scope="$(runtime_scope_for_import "$source_dir" "$removal_manifest")"
  rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file" "$removal_manifest"
  log "Removendo ZIP original somente após todas as confirmações..."
  if ! finalize_import_zip "$zip_file"; then
    log "ERRO: arquivos importados, mas o ZIP não pôde ser removido: $zip_file"
    return 1
  fi

  log "IMPORTAÇÃO CONCLUÍDA"
  log "Destino confirmado: $project_dir"
  signal_auto_deploys_after_import "$project" "$runtime_scope"
  soft_beep
  line
}

import_downloads() {
  local zip_file selected_zip
  local imported=0 failed=0 processed=0
  local -a downloads=()
  local -A attempted=()

  mapfile -t downloads < <(download_inbox_existing_dirs)

  if [ "${#downloads[@]}" -eq 0 ]; then
    log "Downloads não encontrado."
    return 0
  fi

  log "Verificando Downloads: $(download_inbox_summary)"

  # As duas caixas de entrada formam uma única fila drenável no WSL:
  # ~/Downloads + /mnt/c/Users/daniel/Downloads. Depois de cada ZIP processado,
  # ambas são varridas novamente, então um download que terminar no outro lado
  # durante uma importação entra no mesmo ciclo.
  #
  # ZIP desconhecido continua invisível. ZIP que falhar é tentado apenas uma vez
  # nesta drenagem e permanece no diretório de origem para inspeção/correção.
  while true; do
    selected_zip=""

    while IFS= read -r -d '' zip_file; do
      download_zip_is_configured "$zip_file" || continue
      [ -z "${attempted[$zip_file]+x}" ] || continue
      selected_zip="$zip_file"
      break
    done < <(
      find "${downloads[@]}" \
        -maxdepth 1 \
        -type f \
        -iname "*.zip" \
        -print0 2>/dev/null | sort -z
    )

    [ -n "$selected_zip" ] || break

    attempted["$selected_zip"]=1
    processed=$((processed + 1))
    wait_if_paused

    log "FILA DE DOWNLOADS [$processed]: $(basename -- "$selected_zip")"

    if ! download_zip_has_purpose "$(basename -- "$selected_zip")"; then
      log "AVISO PADRÃO DE NOME: use <projeto>--<o-que-faz>.zip; pacote atual não descreve a finalidade."
    fi

    if import_one_zip "$selected_zip"; then
      imported=$((imported + 1))
    else
      failed=$((failed + 1))
      log "ERRO: falha ao importar: $(basename -- "$selected_zip")"
      log "ZIP COM FALHA MANTIDO EM DOWNLOADS: $selected_zip"
    fi
  done

  if [ "$processed" -eq 0 ]; then
    log "Nenhum ZIP de projeto existente/configurado encontrado em Downloads nesta rodada."
    return 0
  fi

  LOG_CONTEXT=download_done log "FILA DE DOWNLOADS DRENADA: $imported sucesso(s), $failed falha(s), $processed processado(s)."
  [ "$failed" -eq 0 ]
}
