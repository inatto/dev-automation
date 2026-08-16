#!/usr/bin/env bash
# Contexto: identificação de ZIP, escopo de atualização e sinalização de runtime

project_for_zip() {
  local zip_name="$1"
  local zip_name_lower zip_stem zip_stem_lower
  local project alias alias_lower suffix first_suffix_char
  local best=""
  local best_name=""

  zip_name_lower="${zip_name,,}"
  [[ "$zip_name_lower" == *.zip ]] || {
    echo ""
    return 0
  }

  # Retira apenas a extensão final. Para projetos aninhados, aceita tanto o
  # nome lógico curto (exec-agent.zip) quanto o backup qualificado gerado pelo
  # manager (dev-automation--exec-agent.zip). O nome lógico é globalmente único.
  zip_stem="${zip_name:0:${#zip_name}-4}"
  zip_stem_lower="${zip_stem,,}"

  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue

    while IFS= read -r alias || [ -n "$alias" ]; do
      [ -n "$alias" ] || continue
      alias_lower="${alias,,}"

      # Aceita o nome exato ou sufixo iniciado por separador não alfanumérico,
      # preservando nomes de arquivos gerados pelo navegador/chat, por exemplo:
      #   exec-agent.zip
      #   exec-agent-incremental.zip
      #   dev-automation--exec-agent.zip
      #   dev-automation--exec-agent(2).zip
      if [[ "$zip_stem_lower" == "$alias_lower" ]]; then
        suffix=""
      elif [[ "$zip_stem_lower" == "$alias_lower"* ]]; then
        suffix="${zip_stem:${#alias}}"
        first_suffix_char="${suffix:0:1}"
        [[ -n "$first_suffix_char" && ! "$first_suffix_char" =~ [[:alnum:]] ]] || continue
      else
        continue
      fi

      if [ "${#alias}" -gt "${#best_name}" ]; then
        best="$project"
        best_name="$alias"
      fi
    done < <(project_import_names "$project")
  done < <(backup_targets)

  echo "$best"
}

worker_from_zip_is_configured() {
  local zip_file="$1"
  local zip_name project

  [ -n "$zip_file" ] || return 1
  zip_name="$(basename -- "$zip_file")"
  project="$(project_for_zip "$zip_name")"
  [ -n "$project" ]
}

worker_from_zip_purpose() {
  local zip_name="$1" project="$2" stem stem_lower alias alias_lower suffix best_alias=""
  [[ "${zip_name,,}" == *.zip ]] || return 1
  stem="${zip_name:0:${#zip_name}-4}"
  stem_lower="${stem,,}"

  while IFS= read -r alias || [ -n "$alias" ]; do
    [ -n "$alias" ] || continue
    alias_lower="${alias,,}"
    if [[ "$stem_lower" == "$alias_lower"* ]] && [ "${#alias}" -gt "${#best_alias}" ]; then
      best_alias="$alias"
    fi
  done < <(project_import_names "$project")

  [ -n "$best_alias" ] || return 1
  suffix="${stem:${#best_alias}}"
  [[ "$suffix" == --* ]] || return 1
  suffix="${suffix#--}"
  [ -n "$suffix" ] || return 1
  printf '%s\n' "$suffix"
}

worker_from_zip_has_purpose() {
  local zip_name="$1" project
  project="$(project_for_zip "$zip_name")"
  [ -n "$project" ] || return 1
  worker_from_zip_purpose "$zip_name" "$project" >/dev/null
}

configured_worker_from_zip_exists() {
  local downloads zip_file

  downloads="$(worker_from_dir)"
  [ -n "$downloads" ] && [ -d "$downloads" ] || return 1

  while IFS= read -r -d '' zip_file; do
    if worker_from_zip_is_configured "$zip_file"; then
      return 0
    fi
  done < <(find "$downloads" -maxdepth 1 -type f -iname '*.zip' -print0 2>/dev/null)

  return 1
}

project_update_scope() {
  local source_dir="$1"
  local rel
  local api=false web=false shared=false runtime=false

  while IFS= read -r -d '' rel; do
    case "$rel" in
      apps/api/tests/*|apps/api/.env.example|apps/web/tests/*|apps/web/.env.example)
        ;;
      apps/api/*)
        api=true; runtime=true ;;
      apps/web/*)
        web=true; runtime=true ;;
      deploy/local/*api*.sh)
        api=true; runtime=true ;;
      deploy/local/*web*.sh)
        web=true; runtime=true ;;
      deploy/local/setup.sh|deploy/local/start.sh|config/*|scripts/*)
        shared=true; runtime=true ;;
      deploy/remote/*|tests/*|docs/*|README|README.*|CHANGELOG|CHANGELOG.*|*.md|.gitignore|.gitattributes)
        ;;
      *)
        # Arquivo de runtime fora das árvores canônicas: por segurança trata
        # como compartilhado. Não reinicia por documentação/testes.
        shared=true; runtime=true ;;
    esac
  done < <(find "$source_dir" -type f -printf '%P\0' 2>/dev/null)

  if [ "$runtime" = false ]; then
    printf 'none\n'
  elif [ "$shared" = true ] || { [ "$api" = true ] && [ "$web" = true ]; }; then
    printf 'both\n'
  elif [ "$api" = true ]; then
    printf 'api\n'
  elif [ "$web" = true ]; then
    printf 'web\n'
  else
    printf 'both\n'
  fi
}

action_matches_update_scope() {
  local action="$1" scope="$2"
  case "$scope" in
    api)
      [[ "$action" == *api* || "$action" == "setup" || "$action" == "start" || "$action" == "run" ]] ;;
    web)
      [[ "$action" == *web* || "$action" == "setup" || "$action" == "start" || "$action" == "run" ]] ;;
    both)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

notify_running_project_update() {
  local project_dir="$1" scope="$2"
  local state_file request_file request_temp pid state_project_dir action signaled=0 stale=0

  [ "$scope" != "none" ] || {
    log "ATUALIZAÇÃO: somente arquivos sem efeito de runtime; nenhum restart necessário."
    return 0
  }
  [ -d "$RUNNING_PROJECTS_DIR" ] || {
    log "ATUALIZAÇÃO: $scope; nenhum comando local ativo registrado para reiniciar."
    return 0
  }

  while IFS= read -r -d '' state_file; do
    pid="$(awk -F= '$1=="PID" {print substr($0,5); exit}' "$state_file" 2>/dev/null || true)"
    state_project_dir="$(awk -F= '$1=="PROJECT_DIR" {print substr($0,13); exit}' "$state_file" 2>/dev/null || true)"
    action="$(awk -F= '$1=="ACTION" {print substr($0,8); exit}' "$state_file" 2>/dev/null || true)"

    if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f -- "$state_file" 2>/dev/null || true
      stale=$((stale + 1))
      continue
    fi
    [ "$state_project_dir" = "$project_dir" ] || continue
    action_matches_update_scope "$action" "$scope" || continue

    request_file="$state_file.request"
    request_temp="$request_file.tmp.$$"
    printf '%s\n' "$scope" > "$request_temp"
    mv -f -- "$request_temp" "$request_file"
    if kill -USR1 "$pid" 2>/dev/null; then
      signaled=$((signaled + 1))
      log "RESTART SOLICITADO: escopo=$scope ação=$action PID=$pid"
    else
      rm -f -- "$request_file" 2>/dev/null || true
    fi
  done < <(find "$RUNNING_PROJECTS_DIR" -maxdepth 1 -type f -name '*.state' -print0 2>/dev/null)

  if [ "$signaled" -eq 0 ]; then
    log "ATUALIZAÇÃO: $scope; projeto não estava rodando por comando global supervisionado. Nada foi iniciado à força."
  else
    log "ATUALIZAÇÃO: $scope; $signaled comando(s) ativo(s) sinalizado(s) após a importação completa."
  fi
  [ "$stale" -eq 0 ] || log "RUNTIME: removido(s) $stale registro(s) obsoleto(s)."
}

