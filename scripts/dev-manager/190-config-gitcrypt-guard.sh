#!/usr/bin/env bash
# Contexto: desbloqueia git-crypt com a chave padrão. Nada além disso.
# Não cria/edita .gitattributes, não altera índice, não faz git add/init.

GITCRYPT_GUARD_SCRIPT="${DEV_MANAGER_GITCRYPT_GUARD_SCRIPT:-$PROJECT_ROOT/scripts/config-gitcrypt-guard.sh}"
GITCRYPT_GUARD_KEY="${DEV_MANAGER_GIT_CRYPT_KEY:-/home/daniel/static/git-reverse-crypt-2.key}"
GITCRYPT_CRITICAL_BEEPED=false

emit_gitcrypt_guard_output() {
  local output_file="$1" line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      CRITICAL:*) LOG_CONTEXT=error log "ERRO: ${line#CRITICAL: }" ;;
      UNLOCK:*) LOG_CONTEXT=ok log "GIT-CRYPT UNLOCK: ${line#UNLOCK: }" ;;
      AVISO:*) LOG_CONTEXT=warning log "$line" ;;
      DETALHE:*) LOG_CONTEXT=wait log "${line#DETALHE: }" ;;
      OK:*) LOG_CONTEXT=ok log "$line" ;;
      INSTALAR:*) LOG_CONTEXT=error log "INSTALAR GIT-CRYPT: ${line#INSTALAR: }" ;;
      RESUMO:*) LOG_CONTEXT=wait log "GIT-CRYPT: ${line#RESUMO: }" ;;
      *) LOG_CONTEXT=wait log "GIT-CRYPT: $line" ;;
    esac
  done < "$output_file"
}

gitcrypt_guard_run() {
  local output_file rc=0 project="${1:-}"

  if [ ! -f "$GITCRYPT_GUARD_SCRIPT" ]; then
    LOG_CONTEXT=error log "ERRO: guard git-crypt ausente: $GITCRYPT_GUARD_SCRIPT"
    return 1
  fi
  [ -x "$GITCRYPT_GUARD_SCRIPT" ] || chmod +x "$GITCRYPT_GUARD_SCRIPT" 2>/dev/null || true

  mkdir -p -- "$STATE_DIR"
  output_file="$(mktemp "$STATE_DIR/gitcrypt-unlock-XXXXXX")" || return 1
  local -a args=(--unlock --code-root "$CODE_ROOT" --projects-file "$PROJECTS_FILE" --key "$GITCRYPT_GUARD_KEY")
  [ -z "$project" ] || args+=(--project "$project")

  "$GITCRYPT_GUARD_SCRIPT" "${args[@]}" > "$output_file" 2>&1 || rc=$?
  emit_gitcrypt_guard_output "$output_file"

  if grep -q '^CRITICAL:' "$output_file" 2>/dev/null; then
    taskbar_status error "CRÍTICO: git-crypt unlock falhou"
    if [ "$GITCRYPT_CRITICAL_BEEPED" = false ]; then
      error_beep
      GITCRYPT_CRITICAL_BEEPED=true
    fi
    rm -f -- "$output_file"
    return 3
  fi

  rm -f -- "$output_file"
  return "$rc"
}

gitcrypt_guard_all() { gitcrypt_guard_run; }

gitcrypt_guard_project() {
  local project="$1"
  target_is_aggregate "$project" && return 0
  gitcrypt_guard_run "$project"
}
