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

windows_download_polling_enabled() {
  local primary windows
  is_wsl_runtime || return 1
  primary="$(download_inbox_dir)"
  windows="$(windows_download_inbox_dir)"
  [ -n "$windows" ] || return 1
  [ "$windows" != "$primary" ] || return 1
  [ -d "$windows" ]
}

windows_configured_download_zip_exists() {
  local windows zip_file
  windows_download_polling_enabled || return 1
  windows="$(windows_download_inbox_dir)"

  while IFS= read -r -d '' zip_file; do
    if download_zip_is_configured "$zip_file"; then
      return 0
    fi
  done < <(find "$windows" -maxdepth 1 -type f -iname '*.zip' -print0 2>/dev/null)

  return 1
}

configured_download_zip_exists() {
  local zip_file
  local -a downloads=()

  mapfile -t downloads < <(download_inbox_existing_dirs)
  [ "${#downloads[@]}" -gt 0 ] || return 1

  while IFS= read -r -d '' zip_file; do
    if download_zip_is_configured "$zip_file"; then
      return 0
    fi
  done < <(find "${downloads[@]}" -maxdepth 1 -type f -iname '*.zip' -print0 2>/dev/null)

  return 1
}

runtime_scope_for_import() {
  local source_dir="$1"
  local removal_manifest="${2:-}"
  local rel
  local has_api=0 has_web=0 has_other=0

  if [ -d "$source_dir" ]; then
    while IFS= read -r -d '' rel; do
      case "$rel" in
        apps/api/*|api/*) has_api=1 ;;
        apps/web/*|web/*) has_web=1 ;;
        *) has_other=1 ;;
      esac
    done < <(find "$source_dir" -type f -printf '%P\0' 2>/dev/null)
  fi

  if [ -n "$removal_manifest" ] && [ -s "$removal_manifest" ]; then
    while IFS= read -r -d '' rel; do
      case "$rel" in
        apps/api/*|api/*) has_api=1 ;;
        apps/web/*|web/*) has_web=1 ;;
        *) has_other=1 ;;
      esac
    done < "$removal_manifest"
  fi

  if [ "$has_other" -eq 0 ] && [ "$has_api" -eq 1 ] && [ "$has_web" -eq 0 ]; then
    printf 'api\n'
  elif [ "$has_other" -eq 0 ] && [ "$has_web" -eq 1 ] && [ "$has_api" -eq 0 ]; then
    printf 'web\n'
  else
    printf 'both\n'
  fi
}

runtime_state_value() {
  local state_file="$1" key="$2"
  awk -v wanted="$key" '
    index($0, wanted "=") == 1 {
      print substr($0, length(wanted) + 2)
      exit
    }
  ' "$state_file" 2>/dev/null
}

signal_auto_deploys_after_import() {
  local project="$1" scope="${2:-both}"
  local project_dir state_file runtime_dir auto_mode pid request_file temp_request deploy_mode
  local signaled=0 stale=0
  local nullglob_was_set=false

  project_dir="$(project_path "$project")"
  case "$scope" in api|web|both) ;; *) scope="both" ;; esac

  log "Escopo de runtime detectado: $scope"
  [ -d "$RUNNING_PROJECTS_DIR" ] || {
    log "AUTO: nenhum deploy auto ativo para $project."
    return 0
  }

  shopt -q nullglob && nullglob_was_set=true
  shopt -s nullglob
  for state_file in "$RUNNING_PROJECTS_DIR"/*.state; do
    auto_mode="$(runtime_state_value "$state_file" AUTO_MODE)"
    [ "$auto_mode" = "1" ] || continue

    runtime_dir="$(runtime_state_value "$state_file" PROJECT_DIR)"
    [ "$runtime_dir" = "$project_dir" ] || continue

    pid="$(runtime_state_value "$state_file" PID)"
    if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f -- "$state_file" "$state_file.request" 2>/dev/null || true
      stale=$((stale + 1))
      continue
    fi

    request_file="$state_file.request"
    temp_request="$request_file.tmp.$$"
    printf '%s\n' "$scope" > "$temp_request"
    mv -f -- "$temp_request" "$request_file"

    if kill -USR1 "$pid" 2>/dev/null; then
      deploy_mode="$(runtime_state_value "$state_file" DEPLOY_MODE)"
      log "AUTO: reinício solicitado para $project (${deploy_mode:-desconhecido}, PID $pid)."
      signaled=$((signaled + 1))
    else
      rm -f -- "$request_file" 2>/dev/null || true
    fi
  done
  [ "$nullglob_was_set" = true ] || shopt -u nullglob

  if [ "$signaled" -eq 0 ]; then
    log "AUTO: nenhum deploy auto ativo para $project."
  else
    log "AUTO: $signaled deploy(s) sinalizado(s) após importação confirmada de $project."
  fi
  [ "$stale" -eq 0 ] || log "AUTO: $stale estado(s) obsoleto(s) removido(s)."
}

finalize_import_zip() {
  local zip_file="$1"
  local downloads downloads_real zip_parent
  local from_downloads=false

  [ -f "$zip_file" ] || return 0
  zip_parent="$(cd -- "$(dirname -- "$zip_file")" && pwd -P)" || return 1

  while IFS= read -r downloads || [ -n "$downloads" ]; do
    [ -n "$downloads" ] || continue
    downloads_real="$(cd -- "$downloads" 2>/dev/null && pwd -P || printf '%s' "$downloads")"
    if [ "$zip_parent" = "$downloads_real" ]; then
      from_downloads=true
      break
    fi
  done < <(download_inbox_dirs)

  # ZIP reconhecido só some depois da importação inteira ter sido confirmada.
  # Vale igualmente para ~/Downloads e para o Downloads montado do Windows.
  if ! rm -f -- "$zip_file" || [ -e "$zip_file" ]; then
    log "ERRO: importação foi aplicada, mas o ZIP não pôde ser removido: $zip_file"
    return 1
  fi

  if [ "$from_downloads" = true ]; then
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
            # Symlink é aceito apenas como entrada ignorável. A extração segura
            # abaixo nunca o materializa nem segue o alvo.
            if kind == stat.S_IFLNK:
                continue
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError(f"tipo especial recusado: {name}")
except Exception as exc:
    print(f"ZIP inseguro: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY_ZIP_SAFE
}


extract_zip_without_symlinks() {
  local zip_file="$1" destination="$2"
  python3 - "$zip_file" "$destination" <<'PY_ZIP_EXTRACT'
import os
import re
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath

archive = sys.argv[1]
root = Path(sys.argv[2]).resolve()

with zipfile.ZipFile(archive) as zf:
    for info in zf.infolist():
        name = info.filename
        if not name or "\x00" in name:
            raise SystemExit(f"entrada ZIP inválida: {name!r}")
        normalized = name.replace("\\", "/")
        if normalized.startswith(("/", "//")) or re.match(r"^[A-Za-z]:/", normalized):
            raise SystemExit(f"caminho absoluto recusado: {name}")
        parts = PurePosixPath(normalized).parts
        if any(part == ".." for part in parts):
            raise SystemExit(f"travessia recusada: {name}")

        mode = (info.external_attr >> 16) & 0xFFFF
        kind = stat.S_IFMT(mode)
        if kind == stat.S_IFLNK:
            continue
        if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise SystemExit(f"tipo especial recusado: {name}")

        target = root.joinpath(*parts)
        resolved_parent = target.parent.resolve()
        if root != resolved_parent and root not in resolved_parent.parents:
            raise SystemExit(f"destino fora da extração: {name}")

        if info.is_dir() or kind == stat.S_IFDIR:
            target.mkdir(parents=True, exist_ok=True)
            permissions = mode & 0o777
            if permissions:
                os.chmod(target, permissions)
            continue

        target.parent.mkdir(parents=True, exist_ok=True)
        with zf.open(info, "r") as src, open(target, "wb") as dst:
            while True:
                chunk = src.read(1024 * 1024)
                if not chunk:
                    break
                dst.write(chunk)
        permissions = mode & 0o777
        if permissions:
            os.chmod(target, permissions)
PY_ZIP_EXTRACT
}

preserve_destination_symlinks_from_staging() {
  local project_dir="$1" staging_dir="$2" rel
  while IFS= read -r -d '' rel; do
    rm -rf -- "$staging_dir/$rel"
  done < <(find "$project_dir" -type l -printf '%P\0' 2>/dev/null)
}

verify_zip_modes_after_extract() {
  local zip_file="$1" destination="$2"
  python3 - "$zip_file" "$destination" <<'PY_ZIP_MODE_VERIFY'
import os
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath

archive = sys.argv[1]
root = Path(sys.argv[2]).resolve()
errors = []

with zipfile.ZipFile(archive) as zf:
    for info in zf.infolist():
        normalized = info.filename.replace("\\", "/")
        parts = PurePosixPath(normalized).parts
        mode = (info.external_attr >> 16) & 0xFFFF
        kind = stat.S_IFMT(mode)
        if kind == stat.S_IFLNK:
            continue
        expected = mode & 0o777
        if not expected:
            # ZIPs sem metadata POSIX não têm modo confiável para conferir.
            continue
        target = root.joinpath(*parts)
        if not target.exists():
            errors.append(f"ausente após extração: {info.filename}")
            continue
        actual = stat.S_IMODE(target.stat().st_mode) & 0o777
        if actual != expected:
            errors.append(f"modo divergente {info.filename}: ZIP={expected:03o} extraído={actual:03o}")

if errors:
    print("ERRO: round-trip de permissões do ZIP falhou:", file=sys.stderr)
    for error in errors[:50]:
        print(f"  {error}", file=sys.stderr)
    raise SystemExit(1)
PY_ZIP_MODE_VERIFY
}

verify_zip_modes_against_tree() {
  local zip_file="$1" tree_root="$2"
  python3 - "$zip_file" "$tree_root" <<'PY_ZIP_TREE_VERIFY'
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath

archive = sys.argv[1]
root = Path(sys.argv[2]).resolve()
errors = []

with zipfile.ZipFile(archive) as zf:
    for info in zf.infolist():
        normalized = info.filename.replace("\\", "/")
        parts = PurePosixPath(normalized).parts
        mode = (info.external_attr >> 16) & 0xFFFF
        kind = stat.S_IFMT(mode)
        if kind == stat.S_IFLNK:
            continue
        expected_path = root.joinpath(*parts)
        if not expected_path.exists():
            continue
        expected = stat.S_IMODE(expected_path.stat().st_mode) & 0o777
        stored = mode & 0o777
        if stored != expected:
            errors.append(f"modo não preservado no ZIP {info.filename}: origem={expected:03o} ZIP={stored:03o}")

if errors:
    print("ERRO: ZIP não preservou permissões da árvore de origem:", file=sys.stderr)
    for error in errors[:50]:
        print(f"  {error}", file=sys.stderr)
    raise SystemExit(1)
PY_ZIP_TREE_VERIFY
}
