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
    # Downloads só atualiza projeto que já existe localmente. Cadastro sem clone
    # continua válido para backup futuro, mas não autoriza criar projeto por ZIP.
    if ! target_is_code_aggregate "$project" && [ ! -d "$(project_path "$project")" ]; then
      continue
    fi

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

download_zip_is_configured() {
  local zip_file="$1"
  local zip_name project

  [ -n "$zip_file" ] || return 1
  zip_name="$(basename -- "$zip_file")"
  project="$(project_for_zip "$zip_name")"
  [ -n "$project" ]
}

download_zip_purpose() {
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

download_zip_has_purpose() {
  local zip_name="$1" project
  project="$(project_for_zip "$zip_name")"
  [ -n "$project" ] || return 1
  download_zip_purpose "$zip_name" "$project" >/dev/null
}

configured_download_zip_exists() {
  local downloads zip_file

  downloads="$(download_inbox_dir)"
  [ -n "$downloads" ] && [ -d "$downloads" ] || return 1

  while IFS= read -r -d '' zip_file; do
    if download_zip_is_configured "$zip_file"; then
      return 0
    fi
  done < <(find "$downloads" -maxdepth 1 -type f -iname '*.zip' -print0 2>/dev/null)

  return 1
}

# Importação não reinicia nem sinaliza processos automaticamente.
# Reinício/deploy é responsabilidade dos comandos explícitos do projeto.

finalize_import_zip() {
  local zip_file="$1"
  local downloads zip_parent downloads_real

  [ -f "$zip_file" ] || return 0
  downloads="$(download_inbox_dir)"
  zip_parent="$(cd -- "$(dirname -- "$zip_file")" && pwd -P)" || return 1
  downloads_real="$(cd -- "$downloads" 2>/dev/null && pwd -P || printf '%s' "$downloads")"

  # Regra local: ZIP reconhecido só some depois da importação inteira ter sido
  # confirmada. Falha nunca chama esta função, portanto o arquivo fica em
  # Downloads para inspeção/correção. ZIP desconhecido nem entra no pipeline.
  if ! rm -f -- "$zip_file" || [ -e "$zip_file" ]; then
    log "ERRO: importação foi aplicada, mas o ZIP não pôde ser removido: $zip_file"
    return 1
  fi

  if [ "$zip_parent" = "$downloads_real" ]; then
    log "ZIP PROCESSADO E REMOVIDO DE DOWNLOADS: $(basename -- "$zip_file")"
  else
    log "ZIP PROCESSADO E REMOVIDO: $zip_file"
  fi
  return 0
}

validate_zip_entries_safe() {
  local zip_file="$1"
  python3 - "$zip_file" <<'PY_ZIP_SAFE'
import re
import stat
import sys
import zipfile
from pathlib import PurePosixPath

path = sys.argv[1]
try:
    with zipfile.ZipFile(path) as zf:
        for info in zf.infolist():
            name = info.filename
            if not name or "\x00" in name:
                raise ValueError("nome vazio/NUL")
            normalized = name.replace("\\", "/")
            if normalized.startswith(("/", "//")) or re.match(r"^[A-Za-z]:/", normalized):
                raise ValueError(f"caminho absoluto: {name}")
            parts = PurePosixPath(normalized).parts
            if any(part == ".." for part in parts):
                raise ValueError(f"travessia de diretório: {name}")
            mode = (info.external_attr >> 16) & 0xFFFF
            kind = stat.S_IFMT(mode)
            if kind == stat.S_IFLNK:
                raise ValueError(f"symlink recusado: {name}")
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError(f"tipo especial recusado: {name}")
except Exception as exc:
    print(f"ZIP inseguro: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY_ZIP_SAFE
}
