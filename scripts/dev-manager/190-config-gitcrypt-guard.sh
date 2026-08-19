#!/usr/bin/env bash
# Contexto: valida e AUTOCORRIGE git-crypt apenas nas configs sensíveis.
# Fluxo: --check -> se houver CRITICAL, --fix com a chave padrão -> --check final.

GITCRYPT_GUARD_SCRIPT="${DEV_MANAGER_GITCRYPT_GUARD_SCRIPT:-$PROJECT_ROOT/scripts/config-gitcrypt-guard.sh}"
GITCRYPT_GUARD_KEY="${DEV_MANAGER_GIT_CRYPT_KEY:-/home/daniel/static/git-reverse-crypt-2.key}"
GITCRYPT_CRITICAL_BEEPED=false

emit_gitcrypt_guard_output() {
  local output_file="$1"
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      CRITICAL:*) LOG_CONTEXT=error log "ERRO: ${line#CRITICAL: }" ;;
      FIX:*) LOG_CONTEXT=warning log "GIT-CRYPT CORRIGIDO: ${line#FIX: }" ;;
      AVISO:*) LOG_CONTEXT=warning log "$line" ;;
      DETALHE:*) LOG_CONTEXT=error log "${line#DETALHE: }" ;;
      OK:*) LOG_CONTEXT=ok log "$line" ;;
      INSTALAR:*) LOG_CONTEXT=error log "INSTALAR GIT-CRYPT: ${line#INSTALAR: }" ;;
      RESUMO:*) LOG_CONTEXT=wait log "GIT-CRYPT: ${line#RESUMO: }" ;;
      *) LOG_CONTEXT=wait log "GIT-CRYPT: $line" ;;
    esac
  done < "$output_file"
}

# Primeira passagem: problema ainda não é erro final, porque o manager vai tentar
# corrigi-lo imediatamente. Mostra caminhos para deixar claro o que foi detectado.
emit_gitcrypt_detected_output() {
  local output_file="$1"
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      CRITICAL:*) LOG_CONTEXT=warning log "GIT-CRYPT DETECTADO: ${line#CRITICAL: }" ;;
      DETALHE:*) LOG_CONTEXT=warning log "${line#DETALHE: }" ;;
      AVISO:*) LOG_CONTEXT=warning log "$line" ;;
      INSTALAR:*) LOG_CONTEXT=warning log "INSTALAR GIT-CRYPT: ${line#INSTALAR: }" ;;
      RESUMO:*) LOG_CONTEXT=wait log "GIT-CRYPT CHECK: ${line#RESUMO: }" ;;
      *) : ;;
    esac
  done < "$output_file"
}

gitcrypt_guard_alert_if_needed() {
  local output_file="$1"
  if ! grep -q '^CRITICAL:' "$output_file" 2>/dev/null; then
    return 0
  fi

  taskbar_status error "CRÍTICO: config sem git-crypt"
  LOG_CONTEXT=error log "ERRO: CRÍTICO — uma ou mais pastas config continuam sem proteção git-crypt depois da autocorreção."
  if [ "$GITCRYPT_CRITICAL_BEEPED" = false ]; then
    error_beep
    GITCRYPT_CRITICAL_BEEPED=true
  fi
  return 1
}

gitcrypt_guard_exec() {
  local mode="$1" output_file="$2"
  shift 2
  local -a args=("$mode" --code-root "$CODE_ROOT" --projects-file "$PROJECTS_FILE" --key "$GITCRYPT_GUARD_KEY")
  [ "$#" -eq 0 ] || args+=(--project "$1")
  "$GITCRYPT_GUARD_SCRIPT" "${args[@]}" > "$output_file" 2>&1
}

gitcrypt_guard_run() {
  local check_file fix_file final_file rc=0
  local project="${1:-}"

  if [ ! -f "$GITCRYPT_GUARD_SCRIPT" ]; then
    LOG_CONTEXT=error log "ERRO: guard git-crypt ausente: $GITCRYPT_GUARD_SCRIPT"
    taskbar_status error "CRÍTICO: guard git-crypt ausente"
    if [ "$GITCRYPT_CRITICAL_BEEPED" = false ]; then error_beep; GITCRYPT_CRITICAL_BEEPED=true; fi
    return 1
  fi
  [ -x "$GITCRYPT_GUARD_SCRIPT" ] || chmod +x "$GITCRYPT_GUARD_SCRIPT" 2>/dev/null || true

  mkdir -p -- "$STATE_DIR"
  check_file="$(mktemp "$STATE_DIR/gitcrypt-check-XXXXXX")" || return 1
  fix_file="$(mktemp "$STATE_DIR/gitcrypt-fix-XXXXXX")" || { rm -f -- "$check_file"; return 1; }
  final_file="$(mktemp "$STATE_DIR/gitcrypt-final-XXXXXX")" || { rm -f -- "$check_file" "$fix_file"; return 1; }

  # 1) Checa sem escrever nada.
  if [ -n "$project" ]; then
    gitcrypt_guard_exec --check "$check_file" "$project" || rc=$?
  else
    gitcrypt_guard_exec --check "$check_file" || rc=$?
  fi

  if ! grep -q '^CRITICAL:' "$check_file" 2>/dev/null; then
    emit_gitcrypt_guard_output "$check_file"
    rm -f -- "$check_file" "$fix_file" "$final_file"
    return 0
  fi

  # 2) Detectou problema: mostra exatamente pasta/arquivos e tenta corrigir.
  emit_gitcrypt_detected_output "$check_file"
  LOG_CONTEXT=warning log "GIT-CRYPT: tentando autocorreção com a chave $GITCRYPT_GUARD_KEY"

  rc=0
  if [ -n "$project" ]; then
    gitcrypt_guard_exec --fix "$fix_file" "$project" || rc=$?
  else
    gitcrypt_guard_exec --fix "$fix_file" || rc=$?
  fi
  emit_gitcrypt_guard_output "$fix_file"

  # 3) Sempre verifica de novo. Só o resultado desta passagem decide se ficou erro.
  rc=0
  if [ -n "$project" ]; then
    gitcrypt_guard_exec --check "$final_file" "$project" || rc=$?
  else
    gitcrypt_guard_exec --check "$final_file" || rc=$?
  fi
  emit_gitcrypt_guard_output "$final_file"

  if gitcrypt_guard_alert_if_needed "$final_file"; then
    taskbar_status done "Git-crypt config corrigido"
    rm -f -- "$check_file" "$fix_file" "$final_file"
    return 0
  fi

  rm -f -- "$check_file" "$fix_file" "$final_file"
  return 3
}

gitcrypt_guard_all() {
  gitcrypt_guard_run
}

gitcrypt_guard_project() {
  local project="$1"
  target_is_aggregate "$project" && return 0
  gitcrypt_guard_run "$project"
}
