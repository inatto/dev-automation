#!/usr/bin/env bash
# Contexto: marcadores .remover, validação, quarentena e rollback

valid_import_relative_path() {
  local rel="$1"
  case "$rel" in
    ""|/*|..|../*|*/../*|*/..) return 1 ;;
    *) return 0 ;;
  esac
}


prepare_removal_markers() {
  local source_root="$1"
  local project_dir="$2"
  local manifest="$3"
  local marker rel target_rel parent part
  local -a parts=()

  : > "$manifest"

  while IFS= read -r -d '' marker; do
    rel="${marker#"$source_root"/}"
    target_rel="${rel%.remover}"

    if [ "$target_rel" = "$rel" ] || ! valid_import_relative_path "$target_rel"; then
      log "ERRO: marcador .remover inválido: $rel"
      return 1
    fi

    # Nunca aceite atravessar um symlink de diretório no destino. Assim um
    # marcador vindo do ZIP não consegue remover algo fora do projeto.
    IFS='/' read -r -a parts <<< "$target_rel"
    parent="$project_dir"
    if [ "${#parts[@]}" -gt 1 ]; then
      for part in "${parts[@]:0:${#parts[@]}-1}"; do
        parent="$parent/$part"
        if [ -L "$parent" ]; then
          log "ERRO: .remover atravessaria symlink de diretório: $target_rel"
          return 1
        fi
      done
    fi

    # Um ZIP não pode simultaneamente entregar e mandar apagar o mesmo alvo.
    if [ -e "$source_root/$target_rel" ] || [ -L "$source_root/$target_rel" ]; then
      log "ERRO: ZIP contém arquivo e .remover para o mesmo alvo: $target_rel"
      return 1
    fi

    printf '%s\0' "$target_rel" >> "$manifest"
    rm -f -- "$marker" || return 1
    log "REMOVER AGENDADO: $target_rel"
  done < <(find "$source_root" -type f -name '*.remover' -print0 2>/dev/null)

  return 0
}

apply_removal_manifest() {
  local project_dir="$1"
  local manifest="$2"
  local rel target marker quarantine slot
  local index=0 rollback_failed=0 i
  local -a moved_rels=() moved_slots=()

  [ -s "$manifest" ] || return 0

  # A remoção é feita por rename para uma quarentena temporária dentro do
  # próprio projeto (mesmo filesystem). Se qualquer rename falhar, tudo que já
  # saiu volta para o lugar antes de a importação ser considerada falha.
  quarantine="$(mktemp -d "$project_dir/.dev-auto-removal-XXXXXX")" || {
    log "ERRO: não foi possível criar quarentena transacional para .remover."
    return 1
  }

  while IFS= read -r -d '' rel; do
    valid_import_relative_path "$rel" || {
      log "ERRO: remoção recusada por caminho inválido: $rel"
      rollback_failed=1
      break
    }

    target="$project_dir/$rel"
    marker="$project_dir/$rel.remover"

    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
      rm -f -- "$marker" 2>/dev/null || true
      log "REMOVIDO: $rel (alvo já ausente)"
      continue
    fi

    index=$((index + 1))
    slot="$quarantine/$index"
    if ! mv -- "$target" "$slot"; then
      log "ERRO: não foi possível mover alvo obsoleto para quarentena: $rel"
      rollback_failed=1
      break
    fi
    moved_rels+=("$rel")
    moved_slots+=("$slot")
  done < "$manifest"

  if [ "$rollback_failed" -ne 0 ]; then
    for ((i=${#moved_rels[@]}-1; i>=0; i--)); do
      rel="${moved_rels[$i]}"
      slot="${moved_slots[$i]}"
      target="$project_dir/$rel"
      mkdir -p -- "$(dirname -- "$target")" || true
      if [ -e "$target" ] || [ -L "$target" ] || ! mv -- "$slot" "$target"; then
        log "ERRO: rollback da remoção não conseguiu restaurar: $rel"
      else
        log "ROLLBACK REMOVER: $rel restaurado"
      fi
    done
    rm -rf -- "$quarantine" 2>/dev/null || true
    return 1
  fi

  # Confirma que todos os alvos saíram do namespace do projeto antes de
  # destruir a quarentena. Até este ponto ainda seria possível restaurá-los.
  while IFS= read -r -d '' rel; do
    target="$project_dir/$rel"
    if [ -e "$target" ] || [ -L "$target" ]; then
      log "ERRO: alvo .remover ainda existe após quarentena: $rel"
      for ((i=${#moved_rels[@]}-1; i>=0; i--)); do
        rel="${moved_rels[$i]}"
        slot="${moved_slots[$i]}"
        target="$project_dir/$rel"
        mkdir -p -- "$(dirname -- "$target")" || true
        [ -e "$target" ] || [ -L "$target" ] || mv -- "$slot" "$target" 2>/dev/null || true
      done
      rm -rf -- "$quarantine" 2>/dev/null || true
      return 1
    fi
  done < "$manifest"

  for rel in "${moved_rels[@]}"; do
    rm -f -- "$project_dir/$rel.remover" 2>/dev/null || true
    log "REMOVIDO: $rel"
  done

  if ! rm -rf -- "$quarantine"; then
    # O alvo já foi removido atomicamente do projeto. Falha de limpeza da
    # quarentena não reintroduz arquivo antigo nem invalida a importação.
    log "ERRO: quarentena de .remover não pôde ser limpa completamente: $quarantine"
    return 1
  fi
  return 0
}

