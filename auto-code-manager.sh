#!/usr/bin/env bash
# cd /home/daniel/Code/infra/dev-automation
set -uo pipefail
#cd /home/daniel/Code/infra/dev-automation/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_VERSION="2026-07-19-codezip-v6-nested-projects"

CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
IGNORE_ZIP_FILE="$SCRIPT_DIR/auto-code-manager.ignore-zip"
IGNORE_UNZIP_FILE="$SCRIPT_DIR/auto-code-manager.ignore-unzip"
PROJECTS_FILE="$SCRIPT_DIR/auto-code-manager.projects"
ENV_FILE="$SCRIPT_DIR/auto-code-manager.env"
DDL_EXPORT_DIR="$CODE_ROOT/infra/sind-infra/sind-oracle/exports/ddl"

# Valores padrão. Podem ser sobrescritos em auto-code-manager.env.
INTERVAL=2
ZONE_EVERY=4
BACKUP_EVERY=10
STABLE_WAIT=2
BEEP_REPEATS=2
BEEP_GAP_MS=220
BEEP_MODE="wave"
BEEP_VOLUME=22
BEEP_WAVE_FILE="$SCRIPT_DIR/sounds/soft-notification.wav"
BEEP_WINDOWS_WAVE_FILE="C:\\Windows\\Media\\notify.wav"

load_env() {
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a
    source "$ENV_FILE"
    set +a
  fi
}

validate_positive_integer() {
  local name="$1"
  local value="${!name:-}"

  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERRO: $name deve ser um número inteiro maior que zero. Valor atual: ${value:-<vazio>}" >&2
    exit 1
  fi
}

validate_timers() {
  validate_positive_integer INTERVAL
  validate_positive_integer ZONE_EVERY
  validate_positive_integer BACKUP_EVERY
  validate_positive_integer STABLE_WAIT
  validate_positive_integer BEEP_REPEATS
  validate_positive_integer BEEP_GAP_MS

  if ! [[ "${BEEP_VOLUME:-}" =~ ^[0-9]+$ ]] || [ "$BEEP_VOLUME" -gt 100 ]; then
    echo "ERRO: BEEP_VOLUME deve ser um inteiro entre 0 e 100. Valor atual: ${BEEP_VOLUME:-<vazio>}" >&2
    exit 1
  fi
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

line() {
  echo "────────────────────────────────────────────────────────────"
}

soft_beep() {
  local repeats="${BEEP_REPEATS:-2}"
  local gap_ms="${BEEP_GAP_MS:-220}"
  local mode="${BEEP_MODE:-wave}"
  local volume="${BEEP_VOLUME:-22}"
  local wave_file="${BEEP_WAVE_FILE:-$SCRIPT_DIR/sounds/soft-notification.wav}"
  local windows_wave="${BEEP_WINDOWS_WAVE_FILE:-C:\\Windows\\Media\\notify.wav}"
  local bundled_windows=""
  local powershell_script=""

  line
  log "AVISO SONORO: iniciando ($repeats toque(s), modo=$mode, volume=$volume%)"

  if command -v powershell.exe >/dev/null 2>&1; then
    log "AVISO SONORO: PowerShell do Windows encontrado."

    if [ "$mode" = "wave" ]; then
      if [ -r "$wave_file" ] && command -v wslpath >/dev/null 2>&1; then
        bundled_windows="$(wslpath -w "$wave_file" 2>/dev/null || true)"
      fi

      # Primeiro tenta o WAV nativo do Windows pedido pelo usuário. Se ele não
      # existir ou falhar, tenta o WAV incluído no projeto.
      powershell_script="\$ErrorActionPreference = 'Stop';
        \$candidates = @('$windows_wave', '$bundled_windows') | Where-Object { \$_ -and (Test-Path -LiteralPath \$_) };
        if (\$candidates.Count -eq 0) { throw 'Nenhum arquivo WAV foi encontrado.' }
        \$played = \$false;
        foreach (\$wav in \$candidates) {
          try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue;
            \$player = New-Object System.Media.SoundPlayer;
            \$player.SoundLocation = \$wav;
            \$player.Load();
            for (\$i = 0; \$i -lt $repeats; \$i++) {
              \$player.PlaySync();
              if (\$i -lt ($repeats - 1)) { Start-Sleep -Milliseconds $gap_ms }
            }
            Write-Output ('OK|' + \$wav);
            \$played = \$true;
            break;
          } catch {
            Write-Output ('FALHOU|' + \$wav + '|' + \$_.Exception.Message);
          }
        }
        if (-not \$played) { exit 2 }"

      local audio_result=""
      audio_result="$(powershell.exe -NoLogo -NoProfile -NonInteractive -STA -Command "$powershell_script" 2>&1 | tr -d '\r')"
      if grep -q '^OK|' <<< "$audio_result"; then
        while IFS= read -r result_line; do
          if [[ "$result_line" == OK\|* ]]; then
            log "AVISO SONORO: WAV tocado pelo Windows: ${result_line#OK|}"
          elif [[ "$result_line" == FALHOU\|* ]]; then
            log "AVISO SONORO: tentativa anterior falhou: ${result_line#FALHOU|}"
          fi
        done <<< "$audio_result"
        line
        return 0
      fi

      log "AVISO SONORO: falha ao tocar WAV pelo Windows. Retorno: ${audio_result:-<sem retorno>}"
    fi

    log "AVISO SONORO: tentando beep eletrônico pelo Windows..."
    if powershell.exe -NoLogo -NoProfile -NonInteractive -Command \
      "\$ErrorActionPreference = 'Stop'; for (\$i = 0; \$i -lt $repeats; \$i++) { [console]::beep(880,220); if (\$i -lt ($repeats - 1)) { Start-Sleep -Milliseconds $gap_ms } }" \
      >/dev/null 2>&1; then
      log "AVISO SONORO: beep eletrônico enviado ao Windows."
      line
      return 0
    fi

    log "AVISO SONORO: beep eletrônico do Windows também falhou."
  else
    log "AVISO SONORO: powershell.exe não está disponível no WSL."
  fi

  log "AVISO SONORO: tentando campainha do terminal/TTY..."
  local i
  local tty_ok=false
  for ((i = 0; i < repeats; i++)); do
    if printf '\a' > /dev/tty 2>/dev/null; then
      tty_ok=true
    else
      printf '\a'
    fi
    sleep "$(awk "BEGIN { print $gap_ms / 1000 }")"
  done

  if [ "$tty_ok" = true ]; then
    log "AVISO SONORO: campainha enviada ao TTY. O tmux/terminal pode estar configurado para silenciá-la."
  else
    log "AVISO SONORO: não foi possível confirmar áudio. Verifique o áudio do Windows e a interoperabilidade WSL."
  fi
  line
}

downloads_dir() {
  local win_profile=""
  local wsl_profile=""

  if command -v cmd.exe >/dev/null 2>&1 &&
     command -v wslpath >/dev/null 2>&1; then

    win_profile="$(
      cmd.exe /c "echo %USERPROFILE%" 2>/dev/null |
      tr -d '\r'
    )"

    if [ -n "$win_profile" ]; then
      wsl_profile="$(wslpath "$win_profile" 2>/dev/null || true)"

      if [ -d "$wsl_profile/Downloads" ]; then
        echo "$wsl_profile/Downloads"
        return
      fi
    fi
  fi

  if [ -d "/mnt/c/Users/${USER}/Downloads" ]; then
    echo "/mnt/c/Users/${USER}/Downloads"
    return
  fi

  echo ""
}

stable_file() {
  local file="$1"
  local size_before
  local size_after

  [ -f "$file" ] || return 1

  size_before="$(stat -c %s "$file" 2>/dev/null || echo 0)"
  sleep "$STABLE_WAIT"

  [ -f "$file" ] || return 1

  size_after="$(stat -c %s "$file" 2>/dev/null || echo 0)"

  [ "$size_before" = "$size_after" ] &&
    [ "$size_before" -gt 0 ]
}

clean_file() {
  local file="$1"

  [ -f "$file" ] || return 0

  sed -E \
    -e 's/\r$//' \
    -e 's/^[[:space:]]+//' \
    -e 's/[[:space:]]+$//' \
    -e '/^$/d' \
    -e '/^#/d' \
    "$file"
}

ensure_files() {
  [ -f "$IGNORE_ZIP_FILE" ] || touch "$IGNORE_ZIP_FILE"
  [ -f "$IGNORE_UNZIP_FILE" ] || touch "$IGNORE_UNZIP_FILE"

  if [ ! -f "$PROJECTS_FILE" ]; then
    echo "site-inst" > "$PROJECTS_FILE"
  fi
}

project_path() {
  local project="$1"

  # As entradas são sempre relativas a CODE_ROOT. Barras finais são removidas.
  project="${project#./}"
  project="${project%/}"

  printf '%s/%s\n' "$CODE_ROOT" "$project"
}

project_archive_name() {
  local project="$1"

  project="${project#./}"
  project="${project%/}"

  # O nome do ZIP é o nome da pasta selecionada. Ex.:
  #   infra                   -> infra.zip
  #   sindicatto/station-app  -> station-app.zip
  basename -- "$project"
}

validate_projects() {
  local project project_dir archive_name
  local seen_file
  local failed=0

  seen_file="$(mktemp /tmp/auto-code-project-names-XXXXXX)"

  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue

    if [[ "$project" = /* || "$project" = *".."* ]]; then
      log "ERRO: entrada inválida em $PROJECTS_FILE: $project"
      failed=1
      continue
    fi

    project_dir="$(project_path "$project")"
    archive_name="$(project_archive_name "$project")"

    if [ ! -d "$project_dir" ]; then
      log "ERRO: projeto/pasta configurado não existe: $project_dir"
      failed=1
    fi

    if grep -Fxq -- "$archive_name" "$seen_file"; then
      log "ERRO: dois itens gerariam o mesmo ZIP '$archive_name.zip'. Use apenas um deles."
      failed=1
    else
      printf '%s\n' "$archive_name" >> "$seen_file"
    fi
  done < <(clean_file "$PROJECTS_FILE")

  rm -f -- "$seen_file"
  [ "$failed" -eq 0 ]
}

project_for_zip() {
  local zip_name="$1"
  local project archive_name
  local best=""
  local best_name=""

  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    archive_name="$(project_archive_name "$project")"

    if [[ "$zip_name" == "$archive_name.zip" ||
          "$zip_name" == "$archive_name"-*.zip ||
          "$zip_name" == "$archive_name"_*.zip ||
          "$zip_name" == "$archive_name"\(*.zip ||
          "$zip_name" == "$archive_name"\ \(*.zip ||
          "$zip_name" == "$archive_name"\ *.zip ]]; then

      if [ "${#archive_name}" -gt "${#best_name}" ]; then
        best="$project"
        best_name="$archive_name"
      fi
    fi
  done < <(clean_file "$PROJECTS_FILE")

  echo "$best"
}

import_one_zip() {
  local zip_file="$1"
  local zip_name project archive_name project_dir temp_dir source_dir filtered_dir unzip_filter_file
  local total_files checked_files rel destination

  zip_name="$(basename "$zip_file")"
  project="$(project_for_zip "$zip_name")"

  if [ -z "$project" ]; then
    log "Ignorando ZIP sem projeto: $zip_name"
    return 0
  fi

  if ! stable_file "$zip_file"; then
    log "ZIP ainda está sendo gravado: $zip_name"
    return 0
  fi

  archive_name="$(project_archive_name "$project")"
  project_dir="$(project_path "$project")"
  temp_dir="$(mktemp -d "/tmp/auto-code-import-${archive_name}-XXXXXX")"

  line
  log "IMPORTAÇÃO INICIADA"
  log "ZIP:        $zip_file"
  log "Projeto:    $project"
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
  else
    source_dir="$temp_dir"
    log "ZIP sem pasta raiz do projeto; usando a raiz do ZIP."
  fi

  filtered_dir="$(mktemp -d "/tmp/auto-code-unzip-filtered-${archive_name}-XXXXXX")"
  unzip_filter_file="$(mktemp "/tmp/auto-code-unzip-filter-${archive_name}-XXXXXX")"
  make_project_rsync_filter \
    "$IGNORE_UNZIP_FILE" \
    "$project_dir" \
    "auto-code-manager.ignore-unzip" \
    "$unzip_filter_file"

  log "Aplicando regras de ignore-unzip..."
  if ! rsync -a --filter="merge $unzip_filter_file" -- "$source_dir/" "$filtered_dir/"; then
    log "ERRO: falha ao aplicar ignore-unzip. O ZIP foi mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"
    return 1
  fi

  source_dir="$filtered_dir"

  total_files="$(find "$source_dir" -type f -printf '.' 2>/dev/null | wc -c)"

  if [ "$total_files" -eq 0 ]; then
    log "ERRO: nenhum arquivo foi extraído. O ZIP foi mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"
    return 1
  fi

  log "Arquivos extraídos: $total_files"
  find "$source_dir" -type f -printf '  EXTRAÍDO: %P\n'

  log "Copiando para o destino..."
  if ! rsync -a --itemize-changes -- "$source_dir/" "$project_dir/" | sed 's/^/  RSYNC: /'; then
    log "ERRO: falha ao copiar. O ZIP foi mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"
    return 1
  fi

  log "Conferindo arquivo por arquivo no destino..."
  checked_files=0

  while IFS= read -r -d '' rel; do
    destination="$project_dir/$rel"

    if [ ! -f "$destination" ]; then
      log "ERRO: arquivo não apareceu no destino: $destination"
      log "ZIP mantido: $zip_file"
      rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"
      return 1
    fi

    if ! cmp -s -- "$source_dir/$rel" "$destination"; then
      log "ERRO: arquivo no destino está diferente: $destination"
      log "ZIP mantido: $zip_file"
      rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"
      return 1
    fi

    checked_files=$((checked_files + 1))
    log "CONFIRMADO [$checked_files/$total_files]: $destination"
  done < <(find "$source_dir" -type f -printf '%P\0')

  if [ "$checked_files" -ne "$total_files" ]; then
    log "ERRO: conferidos $checked_files de $total_files arquivos. ZIP mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"
    return 1
  fi

  rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"

  log "Todos os $checked_files arquivos foram conferidos no destino."
  log "Apagando ZIP original de Downloads..."

  if ! rm -f -- "$zip_file" || [ -e "$zip_file" ]; then
    log "ERRO: arquivos importados, mas o ZIP não foi apagado: $zip_file"
    return 1
  fi

  log "IMPORTAÇÃO CONCLUÍDA"
  log "Destino confirmado: $project_dir"
  log "ZIP apagado: $zip_file"
  soft_beep
  line
}

import_downloads() {
  local downloads

  downloads="$(downloads_dir)"

  if [ -z "$downloads" ] || [ ! -d "$downloads" ]; then
    log "Downloads não encontrado."
    return
  fi

  log "Verificando Downloads: $downloads"

  while IFS= read -r -d '' zip_file; do
    import_one_zip "$zip_file" ||
      log "Falha ao importar: $(basename "$zip_file")"
  done < <(
    find "$downloads" \
      -maxdepth 1 \
      -type f \
      -iname "*.zip" \
      -print0 2>/dev/null
  )
}

clean_zone() {
  log "Limpando Zone.Identifier em $CODE_ROOT"

  find "$CODE_ROOT" \
    -type f \
    -name "*:Zone.Identifier" \
    -delete 2>/dev/null ||
    true
}

make_rsync_filter() {
  local ignore_file="$1"
  local output="$2"
  local pattern
  local action
  local directory

  : > "$output"

  while IFS= read -r pattern || [ -n "$pattern" ]; do
    [ -n "$pattern" ] || continue

    action="-"

    if [[ "$pattern" == !* ]]; then
      action="+"
      pattern="${pattern:1}"
    fi

    if [[ "$pattern" == */ ]]; then
      directory="${pattern%/}"

      if [[ "$directory" == */* ]]; then
        echo "$action /$directory/***" >> "$output"
      else
        echo "$action $directory/***" >> "$output"
        echo "$action **/$directory/***" >> "$output"
      fi
    elif [[ "$pattern" == */* ]]; then
      echo "$action /$pattern" >> "$output"
    else
      echo "$action $pattern" >> "$output"
      echo "$action **/$pattern" >> "$output"
    fi
  done < <(clean_file "$ignore_file")

  echo "- *:Zone.Identifier" >> "$output"
  echo "- **/*:Zone.Identifier" >> "$output"
}

append_scoped_ignore_file() {
  local ignore_file="$1"
  local scope="$2"
  local output="$3"
  local pattern action directory base

  while IFS= read -r pattern || [ -n "$pattern" ]; do
    [ -n "$pattern" ] || continue

    action="-"
    if [[ "$pattern" == !* ]]; then
      action="+"
      pattern="${pattern:1}"
    fi

    # Barra inicial ancora a regra na raiz da pasta que contém o ignore.
    if [[ "$pattern" == /* ]]; then
      pattern="${pattern#/}"
      if [ -n "$scope" ]; then
        echo "$action /$scope/$pattern" >> "$output"
      else
        echo "$action /$pattern" >> "$output"
      fi
      continue
    fi

    base="${scope:+$scope/}"

    if [[ "$pattern" == */ ]]; then
      directory="${pattern%/}"
      echo "$action /$base$directory/***" >> "$output"
      echo "$action /${base}**/$directory/***" >> "$output"
    elif [[ "$pattern" == */* ]]; then
      echo "$action /$base$pattern" >> "$output"
    else
      echo "$action /$base$pattern" >> "$output"
      echo "$action /${base}**/$pattern" >> "$output"
    fi
  done < <(clean_file "$ignore_file")
}

make_project_rsync_filter() {
  local global_ignore_file="$1"
  local project_dir="$2"
  local ignore_filename="$3"
  local output="$4"
  local ignore_file scope count=0

  : > "$output"

  if [ -f "$global_ignore_file" ]; then
    make_rsync_filter "$global_ignore_file" "$output"
  fi

  while IFS= read -r -d '' ignore_file; do
    scope="${ignore_file#"$project_dir"/}"
    scope="${scope%/$ignore_filename}"
    [ "$scope" = "$ignore_filename" ] && scope=""

    log "Usando regras específicas: $ignore_file"
    append_scoped_ignore_file "$ignore_file" "$scope" "$output"
    count=$((count + 1))
  done < <(
    find "$project_dir" \
      -type f \
      -name "$ignore_filename" \
      -print0 2>/dev/null
  )

  if [ "$count" -eq 0 ]; then
    log "Sem arquivos $ignore_filename dentro de $project_dir"
  else
    log "$count arquivo(s) $ignore_filename reconhecido(s) dentro de $project_dir"
  fi

  # Os próprios arquivos de configuração devem continuar no backup, salvo se
  # alguma regra explícita disser o contrário.
}

zip_ddl_exports() {
  local file
  local zip_file

  [ -d "$DDL_EXPORT_DIR" ] || return 0

  log "Compactando DDLs em $DDL_EXPORT_DIR"

  while IFS= read -r -d '' file; do
    zip_file="${file%.*}.zip"

    if [ -f "$zip_file" ] && [ "$zip_file" -nt "$file" ]; then
      continue
    fi

    (
      cd "$(dirname "$file")" || exit 1
      zip -q -j "$(basename "$zip_file")" "$(basename "$file")"
    ) || log "ERRO compactando DDL: $(basename "$file")"

  done < <(
    find "$DDL_EXPORT_DIR" \
      -maxdepth 1 \
      -type f \
      ! -iname "*.zip" \
      ! -name "*:Zone.Identifier" \
      -print0 2>/dev/null
  )
}

backup_project() {
  local project="$1"
  local project_dir
  local archive_name
  local temp_dir
  local temp_zip
  local final_zip
  local filter_file

  project_dir="$(project_path "$project")"
  archive_name="$(project_archive_name "$project")"

  if [ ! -d "$project_dir" ]; then
    log "ERRO: projeto não existe: $project_dir"
    rm -f -- "$CODE_ROOT/$archive_name.zip"
    return 1
  fi

  if [ "$archive_name" = "sind-infra" ] || [ "$project" = "infra" ]; then
    zip_ddl_exports
  fi

  temp_dir="$(mktemp -d "/tmp/auto-code-backup-${archive_name}-XXXXXX")"
  filter_file="$(mktemp "/tmp/auto-code-filter-${archive_name}-XXXXXX")"
  temp_zip="/tmp/${archive_name}-backup-$$.zip"
  final_zip="$CODE_ROOT/$archive_name.zip"

  make_project_rsync_filter \
    "$IGNORE_ZIP_FILE" \
    "$project_dir" \
    "auto-code-manager.ignore-zip" \
    "$filter_file"

  log "Gerando backup: $project -> $final_zip"

  if ! rsync -a \
    --filter="merge $filter_file" \
    "$project_dir/" \
    "$temp_dir/"; then

    log "ERRO no rsync do projeto: $project"
    rm -rf -- "$temp_dir" "$filter_file"
    return 1
  fi

  if ! (
    cd "$temp_dir" &&
    zip -qry "$temp_zip" .
  ); then
    log "ERRO ao compactar projeto: $project"
    rm -rf -- "$temp_dir" "$filter_file" "$temp_zip"
    return 1
  fi

  mv -f -- "$temp_zip" "$final_zip"
  rm -rf -- "$temp_dir" "$filter_file"

  log "OK backup: $final_zip"
}

clean_unmanaged_backup_zips() {
  local zip_file
  local zip_name
  local project
  local managed

  log "Limpando ZIPs de backup fora de $PROJECTS_FILE em $CODE_ROOT"

  while IFS= read -r -d '' zip_file; do
    zip_name="$(basename "$zip_file")"

    # Code.zip é o pacote geral e nunca é removido pela limpeza.
    if [ "$zip_name" = "Code.zip" ] || [ "$zip_name" = "code.zip" ]; then
      continue
    fi

    project="${zip_name%.zip}"
    managed=false

    while IFS= read -r allowed_project || [ -n "$allowed_project" ]; do
      [ -n "$allowed_project" ] || continue

      if [ "$project" = "$(project_archive_name "$allowed_project")" ]; then
        managed=true
        break
      fi
    done < <(clean_file "$PROJECTS_FILE")

    if [ "$managed" = false ]; then
      log "Removendo ZIP fora do .projects: $zip_file"
      rm -f -- "$zip_file" ||
        log "ERRO ao remover ZIP fora do .projects: $zip_file"
    fi
  done < <(
    find "$CODE_ROOT" \
      -maxdepth 1 \
      -type f \
      -iname "*.zip" \
      -print0 2>/dev/null
  )
}

create_code_zip() {
  local final_zip="$CODE_ROOT/Code.zip"
  local staging_dir
  local temp_zip
  local project
  local archive_name
  local project_zip
  local count=0

  staging_dir="$(mktemp -d /tmp/auto-code-package-XXXXXX)"
  temp_zip="$(mktemp /tmp/Code.zip.tmp-XXXXXX)"
  rm -f -- "$temp_zip"

  log "Iniciando criação obrigatória do pacote geral Code.zip..."

  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    archive_name="$(project_archive_name "$project")"
    project_zip="$CODE_ROOT/$archive_name.zip"

    if [ ! -s "$project_zip" ]; then
      log "ERRO: ZIP ausente ou vazio: $project_zip"
      rm -rf -- "$staging_dir"
      rm -f -- "$temp_zip"
      return 1
    fi

    cp -f -- "$project_zip" "$staging_dir/$archive_name.zip" || {
      log "ERRO ao preparar $archive_name.zip para Code.zip"
      rm -rf -- "$staging_dir"
      rm -f -- "$temp_zip"
      return 1
    }
    count=$((count + 1))
  done < <(clean_file "$PROJECTS_FILE")

  if [ "$count" -eq 0 ]; then
    log "ERRO: nenhum projeto configurado para criar Code.zip"
    rm -rf -- "$staging_dir"
    rm -f -- "$temp_zip"
    return 1
  fi

  log "Gerando pacote geral: $count ZIPs -> $final_zip"

  if ! (
    cd "$staging_dir" &&
    zip -q -0 "$temp_zip" -- ./*.zip
  ); then
    log "ERRO ao criar pacote geral Code.zip"
    rm -rf -- "$staging_dir"
    rm -f -- "$temp_zip"
    return 1
  fi

  if [ ! -s "$temp_zip" ] || ! unzip -tq "$temp_zip" >/dev/null 2>&1; then
    log "ERRO: validação do Code.zip falhou"
    rm -rf -- "$staging_dir"
    rm -f -- "$temp_zip"
    return 1
  fi

  # Substituição atômica: o Code.zip anterior só muda depois do novo estar válido.
  if ! mv -f -- "$temp_zip" "$final_zip"; then
    log "ERRO ao instalar o novo Code.zip em $final_zip"
    rm -rf -- "$staging_dir"
    rm -f -- "$temp_zip"
    return 1
  fi

  rm -f -- "$CODE_ROOT/code.zip"
  rm -rf -- "$staging_dir"

  log "OK Code.zip criado e preservado: $final_zip ($count ZIPs)"
  ls -lh -- "$final_zip" 2>/dev/null || true
  return 0
}

backup_all() {
  local project
  local failed=0

  # Nunca apaga o Code.zip válido antes de o novo estar pronto.

  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    backup_project "$project" || failed=1
  done < <(clean_file "$PROJECTS_FILE")

  if [ "$failed" -ne 0 ]; then
    log "ERRO: um ou mais projetos falharam; Code.zip anterior foi mantido; o novo não foi criado neste ciclo."
    return 1
  fi

  log "Todos os projetos foram compactados; chamando create_code_zip agora."
  create_code_zip
}

stop() {
  echo
  line
  echo "Encerrado."
  exit 0
}

trap stop INT TERM

if [ ! -d "$CODE_ROOT" ]; then
  echo "ERRO: diretório não existe: $CODE_ROOT" >&2
  exit 1
fi

ensure_files
load_env
validate_timers

if ! validate_projects; then
  echo "ERRO: corrija $PROJECTS_FILE antes de iniciar." >&2
  exit 1
fi

line
echo "Auto Code Manager - $SCRIPT_VERSION"
line
echo "CODE_ROOT:     $CODE_ROOT"
echo "Downloads:     $(downloads_dir)"
echo "ENV:           $ENV_FILE"
echo "Intervalo:     ${INTERVAL}s"
echo "Backup cada:   ${BACKUP_EVERY}s"
echo "Zone cada:     ${ZONE_EVERY}s"
echo "Estável por:   ${STABLE_WAIT}s"
line

cycle=1
last_backup=0
last_zone=0

while true; do
  now="$(date +%s)"

  line
  log "Ciclo #$cycle"

  import_downloads

  if [ $((now - last_zone)) -ge "$ZONE_EVERY" ]; then
    clean_zone
    last_zone="$now"
  fi

  if [ $((now - last_backup)) -ge "$BACKUP_EVERY" ]; then
    clean_unmanaged_backup_zips
    if backup_all; then
      log "Ciclo de backup concluído com Code.zip."
    else
      log "ERRO: ciclo de backup terminou sem Code.zip."
    fi
    last_backup="$now"
  else
    log "Backup ainda não venceu."
  fi

  cycle=$((cycle + 1))
  sleep "$INTERVAL"
done
