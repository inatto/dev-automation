#!/usr/bin/env bash
# Contexto: auditoria/fix desacoplado de git-crypt para qualquer pasta config.

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
      FIX:*) LOG_CONTEXT=warning log "CORREÇÃO SEGURANÇA: ${line#FIX: }" ;;
      AVISO:*) LOG_CONTEXT=warning log "$line" ;;
      OK:*) LOG_CONTEXT=ok log "$line" ;;
      INSTALAR:*) LOG_CONTEXT=error log "INSTALAR GIT-CRYPT: ${line#INSTALAR: }" ;;
      RESUMO:*) LOG_CONTEXT=wait log "GIT-CRYPT: ${line#RESUMO: }" ;;
      *) LOG_CONTEXT=wait log "GIT-CRYPT: $line" ;;
    esac
  done < "$output_file"
}

gitcrypt_guard_alert_if_needed() {
  local output_file="$1"
  if ! grep -q '^CRITICAL:' "$output_file" 2>/dev/null; then
    return 0
  fi

  taskbar_status error "CRÍTICO: config sem git-crypt"
  LOG_CONTEXT=error log "ERRO: CRÍTICO — uma ou mais pastas config não estão comprovadamente protegidas por git-crypt."
  # Uma campainha crítica por sessão do manager basta; os detalhes vermelhos
  # continuam aparecendo para cada projeto sem transformar o desktop em sirene.
  if [ "$GITCRYPT_CRITICAL_BEEPED" = false ]; then
    error_beep
    GITCRYPT_CRITICAL_BEEPED=true
  fi
  return 1
}

gitcrypt_guard_run() {
  local output_file rc=0
  local -a args=(--fix --code-root "$CODE_ROOT" --projects-file "$PROJECTS_FILE" --key "$GITCRYPT_GUARD_KEY")
  [ "$#" -eq 0 ] || args+=(--project "$1")

  if [ ! -f "$GITCRYPT_GUARD_SCRIPT" ]; then
    LOG_CONTEXT=error log "ERRO: guard git-crypt ausente: $GITCRYPT_GUARD_SCRIPT"
    taskbar_status error "CRÍTICO: guard git-crypt ausente"
    if [ "$GITCRYPT_CRITICAL_BEEPED" = false ]; then error_beep; GITCRYPT_CRITICAL_BEEPED=true; fi
    return 1
  fi
  [ -x "$GITCRYPT_GUARD_SCRIPT" ] || chmod +x "$GITCRYPT_GUARD_SCRIPT" 2>/dev/null || true

  mkdir -p -- "$STATE_DIR"
  output_file="$(mktemp "$STATE_DIR/gitcrypt-guard-XXXXXX")" || return 1
  "$GITCRYPT_GUARD_SCRIPT" "${args[@]}" > "$output_file" 2>&1 || rc=$?
  emit_gitcrypt_guard_output "$output_file"
  gitcrypt_guard_alert_if_needed "$output_file" || rc=3
  rm -f -- "$output_file"
  return "$rc"
}

gitcrypt_guard_all() {
  gitcrypt_guard_run
}

gitcrypt_guard_project() {
  local project="$1"
  target_is_aggregate "$project" && return 0
  gitcrypt_guard_run "$project"
}
