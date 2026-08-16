#!/usr/bin/env bash
# Contexto: importação transacional de ZIPs e worker/from

import_one_zip() {
  local zip_file="$1"
  local skip_stable="${2:-false}"
  local zip_name project archive_name logical_name project_dir temp_dir source_dir filtered_dir unzip_filter_file removal_manifest
  local total_files checked_files rel destination update_scope="none" removal_count=0
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

  log "Extraindo ZIP para a pasta temporária..."
  if ! unzip -oq -- "$zip_file" -d "$temp_dir"; then
    log "ERRO: falha ao extrair. O ZIP foi mantido."
    rm -rf -- "$temp_dir"
    return 1
  fi

  if [ -d "$temp_dir/$archive_name" ]; then
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
    if ! rm -f -- "$zip_file" || [ -e "$zip_file" ]; then
      log "ERRO: filhos importados, mas o ZIP agregador não foi apagado: $zip_file"
      return 1
    fi
    log "$nested_count ZIP(s) filho(s) importado(s) e confirmado(s)."
    log "IMPORTAÇÃO DE AGREGADOR CONCLUÍDA: $project"
    soft_beep
    line
    return 0
  fi

  filtered_dir="$(mktemp -d "/tmp/auto-code-unzip-filtered-${archive_name}-XXXXXX")"
  unzip_filter_file="$(mktemp "/tmp/auto-code-unzip-filter-${archive_name}-XXXXXX")"
  removal_manifest="$(mktemp "/tmp/auto-code-remover-${archive_name}-XXXXXX")"
  make_project_rsync_filter \
    "$IGNORE_UNZIP_FILE" \
    "$project_dir" \
    "auto-code-manager.ignore-unzip" \
    "$unzip_filter_file"

  {
    echo "- **/config/local/***"
    echo "- **/config/remote/***"
    echo "- **/config/production/***"
  } >> "$unzip_filter_file"

  log "Protegendo no unzip: */config/local/**, */config/remote/** e */config/production/**"
  log "Aplicando regras de ignore-unzip..."
  if ! rsync -a --filter="merge $unzip_filter_file" -- "$source_dir/" "$filtered_dir/"; then
    log "ERRO: falha ao aplicar ignore-unzip. O ZIP foi mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file" "$removal_manifest"
    return 1
  fi

  if ! materialize_changed_protected_configs "$project" "$source_dir" "$filtered_dir"; then
    log "ERRO: falha ao comparar configs protegidos. O ZIP foi mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file" "$removal_manifest"
    return 1
  fi

  # Reconstitui configs protegidos no staging antes de tocar no projeto. Onde o
  # backup trouxe ********, conserva o segredo real que já existe localmente.
  if ! merge_import_external_configs "$project_dir" "$filtered_dir"; then
    log "ERRO: merge de .external falhou. O ZIP foi mantido e o destino não recebeu o staging."
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

  update_scope="$(project_update_scope "$source_dir")"
  # Remoção pode atingir API/Web sem haver arquivo correspondente no staging;
  # por segurança, qualquer .remover concluído sinaliza ambos os runtimes.
  if [ "$removal_count" -gt 0 ]; then
    update_scope="both"
  fi
  log "Escopo de runtime detectado: $update_scope"
  rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file" "$removal_manifest"
  log "Apagando ZIP original somente após todas as confirmações..."
  if ! rm -f -- "$zip_file" || [ -e "$zip_file" ]; then
    log "ERRO: arquivos importados, mas o ZIP não foi apagado: $zip_file"
    return 1
  fi

  log "IMPORTAÇÃO CONCLUÍDA"
  log "Destino confirmado: $project_dir"
  log "ZIP apagado: $zip_file"
  notify_running_project_update "$project_dir" "$update_scope"
  soft_beep
  line
}

import_worker_from() {
  local downloads zip_file
  local total index imported=0 failed=0
  local -a zip_files=()

  downloads="$(worker_from_dir)"

  if [ -z "$downloads" ] || [ ! -d "$downloads" ]; then
    log "worker/from não encontrado."
    return 0
  fi

  log "Verificando worker/from: $downloads"

  # A fila de importação é EXCLUSIVAMENTE o que está cadastrado no .projects.
  # ZIP aleatório em worker/from (ROM, instalador, pacote etc.) é invisível para
  # o manager: não entra no lote, não é apagado e não mantém o monitor em loop.
  while IFS= read -r -d '' zip_file; do
    worker_from_zip_is_configured "$zip_file" || continue
    zip_files+=("$zip_file")
  done < <(
    find "$downloads" \
      -maxdepth 1 \
      -type f \
      -iname "*.zip" \
      -print0 2>/dev/null | sort -z
  )

  total="${#zip_files[@]}"
  if [ "$total" -eq 0 ]; then
    log "Nenhum ZIP configurado no .projects encontrado em worker/from nesta rodada."
    return 0
  fi

  log "LOTE DE WORKER/FROM: $total ZIP(s) serão processados em sequência antes de continuar o ciclo."

  for ((index = 0; index < total; index++)); do
    wait_if_paused
    zip_file="${zip_files[$index]}"
    log "LOTE [$((index + 1))/$total]: $(basename -- "$zip_file")"

    if ! worker_from_zip_has_purpose "$(basename -- "$zip_file")"; then
      log "AVISO PADRÃO DE NOME: use <projeto>--<o-que-faz>.zip; pacote atual não descreve a finalidade."
    fi

    if import_one_zip "$zip_file"; then
      imported=$((imported + 1))
    else
      failed=$((failed + 1))
      log "ERRO: falha ao importar: $(basename -- "$zip_file")"
      # Falha de ZIP reconhecido é terminal para esta entrada da fila. Manter o
      # arquivo em worker/from faria o inotify reprocessar o mesmo erro em loop.
      if rm -f -- "$zip_file" && [ ! -e "$zip_file" ]; then
        log "ZIP com falha apagado para evitar reprocessamento: $zip_file"
      else
        log "ERRO: ZIP com falha não pôde ser apagado: $zip_file"
      fi
    fi
  done

  LOG_CONTEXT=download_done log "LOTE DE WORKER/FROM CONCLUÍDO: $imported sucesso(s), $failed falha(s), $total processado(s)."
  [ "$failed" -eq 0 ]
}

