#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation
set -uo pipefail
#cd /home/daniel/Code/bots/dev-automation/
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SCRIPT_VERSION="2026-07-28-codezip-v17-described-cycles"

CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
IGNORE_ZIP_FILE="$PROJECT_ROOT/config/auto-code-manager.ignore-zip"
IGNORE_UNZIP_FILE="$PROJECT_ROOT/config/auto-code-manager.ignore-unzip"
PROJECTS_FILE="$PROJECT_ROOT/config/auto-code-manager.projects"
ENV_FILE="$PROJECT_ROOT/config/auto-code-manager.env"
FOLDER_SQL_ZIP_FILE="$PROJECT_ROOT/config/auto-code-manager.folder-sql-zip"
STATE_DIR="${AUTO_CODE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dev-automation}"
PROTECTED_CONFIG_BASELINES_DIR="$STATE_DIR/protected-config-baselines"

# Valores padrão. Podem ser sobrescritos em auto-code-manager.env.
INTERVAL=2
ZONE_EVERY=4
BACKUP_EVERY=10
STABLE_WAIT=2
BEEP_REPEATS=2
BEEP_GAP_MS=220
BEEP_MODE="wave"
BEEP_VOLUME=22
BEEP_WAVE_FILE="$PROJECT_ROOT/assets/sounds/soft-notification.wav"
BEEP_WINDOWS_WAVE_FILE="C:\\Windows\\Media\\notify.wav"
BACKUP_BEEP_ENABLED=true
BACKUP_BEEP_VOLUME=18
BACKUP_BEEP_WAVE_FILE="$PROJECT_ROOT/assets/sounds/backup-complete.wav"
BACKUP_WINDOWS_WAVE_FILE="C:\\Windows\\Media\\ding.wav"
TASKBAR_STATUS_ENABLED=true
DEV_STATUS_INVOKE_PS1="$PROJECT_ROOT/apps/dev-status/invoke.ps1"
DEV_STATUS_EXE="$PROJECT_ROOT/apps/dev-status/bin/dev-status.exe"

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

  if ! [[ "${BACKUP_BEEP_VOLUME:-}" =~ ^[0-9]+$ ]] || [ "$BACKUP_BEEP_VOLUME" -gt 100 ]; then
    echo "ERRO: BACKUP_BEEP_VOLUME deve ser um inteiro entre 0 e 100. Valor atual: ${BACKUP_BEEP_VOLUME:-<vazio>}" >&2
    exit 1
  fi

  case "${BACKUP_BEEP_ENABLED:-}" in
    true|false) ;;
    *)
      echo "ERRO: BACKUP_BEEP_ENABLED deve ser true ou false. Valor atual: ${BACKUP_BEEP_ENABLED:-<vazio>}" >&2
      exit 1
      ;;
  esac
}

color_enabled() {
  [ -t 1 ] && [ "${NO_COLOR:-}" = "" ] && [ "${TERM:-dumb}" != "dumb" ]
}

color_code() {
  case "$1" in
    cycle) printf '1;36' ;;    # ciano forte
    downloads) printf '1;34' ;;# azul
    sql) printf '1;35' ;;      # magenta
    zone) printf '1;33' ;;     # amarelo
    backup) printf '1;32' ;;   # verde
    wait) printf '2;37' ;;     # cinza
    error) printf '1;31' ;;    # vermelho
    *) printf '0' ;;
  esac
}

paint() {
  local context="$1"
  shift
  if color_enabled; then
    printf '\033[%sm%s\033[0m' "$(color_code "$context")" "$*"
  else
    printf '%s' "$*"
  fi
}

log() {
  local message="$*"
  local context="${LOG_CONTEXT:-}"

  if [[ "$message" == ERRO:* ]]; then
    context="error"
  fi

  printf '[%s] ' "$(date '+%Y-%m-%d %H:%M:%S')"
  if [ -n "$context" ]; then
    paint "$context" "$message"
    printf '\n'
  else
    printf '%s\n' "$message"
  fi
}

stage() {
  local context="$1"
  local state="$2"
  local title="$3"
  local description="${4:-}"
  local marker='▶'

  [ "$state" = 'end' ] && marker='✓'
  [ "$state" = 'skip' ] && marker='·'

  printf '\n'
  paint "$context" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf '\n'
  paint "$context" "$marker $title"
  printf '\n'
  if [ -n "$description" ]; then
    paint "$context" "  $description"
    printf '\n'
  fi
  paint "$context" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf '\n'
}

taskbar_status() {
  local state="$1"
  local detail="${2:-}"
  local invoke_windows

  [ "${TASKBAR_STATUS_ENABLED:-true}" = true ] || return 0
  [ -f "$DEV_STATUS_EXE" ] || return 0
  [ -f "$DEV_STATUS_INVOKE_PS1" ] || return 0
  command -v powershell.exe >/dev/null 2>&1 || return 0
  command -v wslpath >/dev/null 2>&1 || return 0

  invoke_windows="$(wslpath -w "$DEV_STATUS_INVOKE_PS1" 2>/dev/null)" || return 0
  powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$invoke_windows" -State "$state" -Detail "$detail" >/dev/null 2>&1 || true
}

run_stage() {
  local context="$1"
  local title="$2"
  local description="$3"
  shift 3

  stage "$context" start "$title — INÍCIO" "$description"
  if LOG_CONTEXT="$context" "$@"; then
    stage "$context" end "$title — CONCLUÍDO"
    return 0
  fi

  taskbar_status error "$title"
  LOG_CONTEXT=error log "ERRO: etapa '$title' terminou com falha."
  return 1
}

line() {
  echo "────────────────────────────────────────────────────────────"
}

soft_beep() {
  local repeats="${BEEP_REPEATS:-2}"
  local gap_ms="${BEEP_GAP_MS:-220}"
  local mode="${BEEP_MODE:-wave}"
  local volume="${BEEP_VOLUME:-22}"
  local wave_file="${BEEP_WAVE_FILE:-$PROJECT_ROOT/assets/sounds/soft-notification.wav}"
  local windows_wave="${BEEP_WINDOWS_WAVE_FILE:-C:\\Windows\\Media\\notify.wav}"
  local bundled_windows=""
  local powershell_cmd=""
  local powershell_probe=""
  local powershell_script=""
  local audio_result=""
  local i

  line
  log "AVISO SONORO: iniciando ($repeats toque(s), modo=$mode, volume=$volume%)"

  # No WSLg, PulseAudio/PipeWire normalmente é a rota mais direta e não depende
  # da interoperabilidade com executáveis do Windows.
  if [ "$mode" = "wave" ] && [ -r "$wave_file" ]; then
    if command -v paplay >/dev/null 2>&1; then
      log "AVISO SONORO: tentando WAV pelo paplay do WSL..."
      for ((i = 0; i < repeats; i++)); do
        if ! paplay --volume="$((volume * 65536 / 100))" "$wave_file" >/dev/null 2>&1; then
          break
        fi
        [ "$i" -ge $((repeats - 1)) ] || sleep "$(awk "BEGIN { print $gap_ms / 1000 }")"
      done
      if [ "$i" -eq "$repeats" ]; then
        log "AVISO SONORO: WAV tocado pelo áudio nativo do WSL (paplay)."
        line
        return 0
      fi
      log "AVISO SONORO: paplay existe, mas não conseguiu tocar o WAV."
    fi

    if command -v pw-play >/dev/null 2>&1; then
      log "AVISO SONORO: tentando WAV pelo PipeWire do WSL..."
      for ((i = 0; i < repeats; i++)); do
        if ! pw-play --volume="$(awk "BEGIN { print $volume / 100 }")" "$wave_file" >/dev/null 2>&1; then
          break
        fi
        [ "$i" -ge $((repeats - 1)) ] || sleep "$(awk "BEGIN { print $gap_ms / 1000 }")"
      done
      if [ "$i" -eq "$repeats" ]; then
        log "AVISO SONORO: WAV tocado pelo áudio nativo do WSL (pw-play)."
        line
        return 0
      fi
      log "AVISO SONORO: pw-play existe, mas não conseguiu tocar o WAV."
    fi

    if command -v aplay >/dev/null 2>&1; then
      log "AVISO SONORO: tentando WAV pelo ALSA do WSL..."
      for ((i = 0; i < repeats; i++)); do
        if ! aplay -q "$wave_file" >/dev/null 2>&1; then
          break
        fi
        [ "$i" -ge $((repeats - 1)) ] || sleep "$(awk "BEGIN { print $gap_ms / 1000 }")"
      done
      if [ "$i" -eq "$repeats" ]; then
        log "AVISO SONORO: WAV tocado pelo áudio nativo do WSL (aplay)."
        line
        return 0
      fi
      log "AVISO SONORO: aplay existe, mas não conseguiu tocar o WAV."
    fi
  fi

  powershell_cmd="$(command -v powershell.exe 2>/dev/null || true)"
  if [ -n "$powershell_cmd" ]; then
    powershell_probe="$($powershell_cmd -NoLogo -NoProfile -NonInteractive -Command "exit 0" 2>&1 || true)"
    if [ -z "$powershell_probe" ]; then
      log "AVISO SONORO: interoperabilidade WSL/Windows operacional."

      if [ "$mode" = "wave" ]; then
        if [ -r "$wave_file" ] && command -v wslpath >/dev/null 2>&1; then
          bundled_windows="$(wslpath -w "$wave_file" 2>/dev/null || true)"
        fi

        powershell_script="\$ErrorActionPreference = 'Stop';
          \$candidates = @('$windows_wave', '$bundled_windows') | Where-Object { \$_ -and (Test-Path -LiteralPath \$_) };
          if (\$candidates.Count -eq 0) { throw 'Nenhum arquivo WAV foi encontrado.' }
          foreach (\$wav in \$candidates) {
            try {
              \$player = New-Object System.Media.SoundPlayer;
              \$player.SoundLocation = \$wav;
              \$player.Load();
              for (\$i = 0; \$i -lt $repeats; \$i++) {
                \$player.PlaySync();
                if (\$i -lt ($repeats - 1)) { Start-Sleep -Milliseconds $gap_ms }
              }
              Write-Output ('OK|' + \$wav);
              exit 0;
            } catch {
              Write-Output ('FALHOU|' + \$wav + '|' + \$_.Exception.Message);
            }
          }
          exit 2"

        audio_result="$($powershell_cmd -NoLogo -NoProfile -NonInteractive -STA -Command "$powershell_script" 2>&1 | tr -d '\r')"
        if grep -q '^OK|' <<< "$audio_result"; then
          log "AVISO SONORO: WAV tocado pelo Windows: $(grep '^OK|' <<< "$audio_result" | tail -n1 | cut -d'|' -f2-)"
          line
          return 0
        fi
        log "AVISO SONORO: Windows não conseguiu tocar o WAV. Retorno: ${audio_result:-<sem retorno>}"
      fi

      log "AVISO SONORO: tentando beep eletrônico pelo Windows..."
      if "$powershell_cmd" -NoLogo -NoProfile -NonInteractive -Command \
        "for (\$i = 0; \$i -lt $repeats; \$i++) { [console]::beep(880,220); if (\$i -lt ($repeats - 1)) { Start-Sleep -Milliseconds $gap_ms } }" \
        >/dev/null 2>&1; then
        log "AVISO SONORO: beep eletrônico enviado ao Windows."
        line
        return 0
      fi
      log "AVISO SONORO: beep eletrônico do Windows também falhou."
    else
      log "AVISO SONORO: powershell.exe existe, mas o WSL não consegue executá-lo."
      log "AVISO SONORO: retorno da interoperabilidade: $powershell_probe"
    fi
  else
    log "AVISO SONORO: powershell.exe não está disponível no PATH do WSL."
  fi

  log "AVISO SONORO: tentando campainha do terminal/TTY..."
  local tty_ok=false
  for ((i = 0; i < repeats; i++)); do
    if printf '\a' > /dev/tty 2>/dev/null; then
      tty_ok=true
    else
      printf '\a'
    fi
    [ "$i" -ge $((repeats - 1)) ] || sleep "$(awk "BEGIN { print $gap_ms / 1000 }")"
  done

  if [ "$tty_ok" = true ]; then
    log "AVISO SONORO: campainha enviada ao TTY, mas o terminal pode estar silenciando-a."
  else
    log "AVISO SONORO: nenhuma saída de áudio disponível."
  fi
  line
  return 1
}

backup_beep() {
  [ "${BACKUP_BEEP_ENABLED:-true}" = "true" ] || return 0

  local windows_wave="${BACKUP_WINDOWS_WAVE_FILE:-C:\\Windows\\Media\\ding.wav}"
  local powershell_cmd=""
  local escaped_windows_wave=""

  # O backup usa prioritariamente o som nativo solicitado do Windows. O
  # SoundPlayer respeita o volume geral do sistema e bloqueia até o fim do WAV,
  # evitando sobreposição quando vários backups terminam em sequência.
  powershell_cmd="$(command -v powershell.exe 2>/dev/null || true)"
  if [ -n "$powershell_cmd" ]; then
    escaped_windows_wave="${windows_wave//\'/\'\'}"
    if "$powershell_cmd" -NoLogo -NoProfile -NonInteractive -STA -Command \
      "\$ErrorActionPreference = 'Stop'; \
       \$wav = '$escaped_windows_wave'; \
       if (-not (Test-Path -LiteralPath \$wav)) { throw 'Arquivo WAV de backup não encontrado.' }; \
       \$player = New-Object System.Media.SoundPlayer; \
       \$player.SoundLocation = \$wav; \
       \$player.Load(); \
       \$player.PlaySync()" \
      >/dev/null 2>&1; then
      return 0
    fi
  fi

  # Fallback discreto para ambientes sem interoperabilidade WSL/Windows ou sem
  # o ding.wav. Não altera o aviso sonoro usado após downloads/importações.
  (
    BEEP_REPEATS=1
    BEEP_GAP_MS=1
    BEEP_MODE="wave"
    BEEP_VOLUME="${BACKUP_BEEP_VOLUME:-18}"
    BEEP_WAVE_FILE="${BACKUP_BEEP_WAVE_FILE:-$PROJECT_ROOT/assets/sounds/backup-complete.wav}"
    BEEP_WINDOWS_WAVE_FILE="__backup_native_wave_disabled__"
    soft_beep
  ) >/dev/null 2>&1 || true

  return 0
}

downloads_dir() {
  local configured_downloads="${DOWNLOADS_DIR:-}"
  local win_profile=""
  local wsl_profile=""

  if [ -n "$configured_downloads" ] && [ -d "$configured_downloads" ]; then
    printf '%s\n' "$configured_downloads"
    return
  fi

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
  [ -f "$FOLDER_SQL_ZIP_FILE" ] || touch "$FOLDER_SQL_ZIP_FILE"
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
  #   orgs/station-app  -> station-app.zip
  basename -- "$project"
}

project_archive_path() {
  local project="$1"
  local archive_name

  # Independentemente da categoria do projeto (bots, orgs, infra, etc.),
  # todos os ZIPs de backup ficam diretamente na raiz de CODE_ROOT.
  archive_name="$(project_archive_name "$project")"
  printf '%s/%s.zip\n' "$CODE_ROOT" "$archive_name"
}

configured_projects() {
  clean_file "$PROJECTS_FILE"
}

inferred_parent_projects() {
  local project parent
  local -a parents=()
  declare -A seen=()

  # O primeiro segmento é a categoria de CODE_ROOT (orgs, infra, bots, ...).
  # Qualquer nível intermediário abaixo dela vira um agrupador de backup.
  # Ex.:
  #   orgs/orbital/orbital-app -> orgs/orbital
  #   orgs/acme/platform/api   -> orgs/acme/platform e orgs/acme
  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    project="${project#./}"
    project="${project%/}"
    parent="${project%/*}"

    while [[ "$parent" == */* ]]; do
      if [ -z "${seen[$parent]+x}" ]; then
        parents+=("$parent")
        seen["$parent"]=1
      fi
      parent="${parent%/*}"
    done
  done < <(configured_projects)

  # Grupos mais profundos precisam ser gerados antes dos seus pais para que o
  # ZIP do filho já exista quando o pacote do nível acima for montado.
  if [ "${#parents[@]}" -gt 0 ]; then
    printf '%s\n' "${parents[@]}" \
      | awk -F/ '{ print NF "\t" $0 }' \
      | sort -t $'\t' -k1,1nr -k2,2 \
      | cut -f2-
  fi
}

direct_child_projects() {
  local parent="$1"
  local project

  # Filhos imediatos podem ser projetos configurados ou agrupadores inferidos.
  # Assim a mesma regra funciona em qualquer profundidade sem nomes especiais.
  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    [ "$project" != "$parent" ] || continue

    if [ "${project%/*}" = "$parent" ]; then
      printf '%s\n' "$project"
    fi
  done < <(backup_targets)
}

backup_targets() {
  local project
  declare -A seen=()

  # Primeiro preserva todos os projetos individuais configurados.
  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    project="${project#./}"
    project="${project%/}"

    if [ -z "${seen[$project]+x}" ]; then
      printf '%s\n' "$project"
      seen["$project"]=1
    fi
  done < <(configured_projects)

  # Depois acrescenta uma única vez cada pasta pai inferida.
  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue

    if [ -z "${seen[$project]+x}" ]; then
      printf '%s\n' "$project"
      seen["$project"]=1
    fi
  done < <(inferred_parent_projects)
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
      log "ERRO: dois alvos gerariam o mesmo ZIP '$archive_name.zip'. Use apenas um deles."
      failed=1
    else
      printf '%s\n' "$archive_name" >> "$seen_file"
    fi
  done < <(backup_targets)

  rm -f -- "$seen_file"
  [ "$failed" -eq 0 ]
}

project_for_zip() {
  local zip_name="$1"
  local zip_name_lower zip_stem zip_stem_lower
  local project archive_name archive_name_lower suffix first_suffix_char
  local best=""
  local best_name=""

  zip_name_lower="${zip_name,,}"
  [[ "$zip_name_lower" == *.zip ]] || {
    echo ""
    return 0
  }

  # Retira apenas a extensão final. A comparação é case-insensitive para aceitar
  # nomes alterados pelo navegador, mas o projeto retornado preserva o config.
  zip_stem="${zip_name:0:${#zip_name}-4}"
  zip_stem_lower="${zip_stem,,}"

  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    archive_name="$(project_archive_name "$project")"
    archive_name_lower="${archive_name,,}"

    # Aceita o nome exato ou qualquer sufixo iniciado por separador não
    # alfanumérico. Exemplos válidos:
    #   dev-automation.zip
    #   dev-automation(15).zip
    #   dev-automation%23232-3434.zip
    #   dev-automation#revisado.zip
    # Evita falsos positivos como dev-automation2.zip.
    if [[ "$zip_stem_lower" == "$archive_name_lower" ]]; then
      suffix=""
    elif [[ "$zip_stem_lower" == "$archive_name_lower"* ]]; then
      suffix="${zip_stem:${#archive_name}}"
      first_suffix_char="${suffix:0:1}"
      [[ -n "$first_suffix_char" && ! "$first_suffix_char" =~ [[:alnum:]] ]] || continue
    else
      continue
    fi

    if [ "${#archive_name}" -gt "${#best_name}" ]; then
      best="$project"
      best_name="$archive_name"
    fi
  done < <(backup_targets)

  echo "$best"
}

import_one_zip() {
  local zip_file="$1"
  local skip_stable="${2:-false}"
  local zip_name project archive_name project_dir temp_dir source_dir filtered_dir unzip_filter_file
  local total_files checked_files rel destination
  local nested_zip nested_project nested_count=0 nested_index
  local -a nested_zips=() nested_projects=()
  local -A nested_seen=()

  zip_name="$(basename "$zip_file")"
  project="$(project_for_zip "$zip_name")"

  if [ -z "$project" ]; then
    log "Ignorando ZIP sem projeto: $zip_name"
    return 0
  fi

  if [ "$skip_stable" != "true" ] && ! stable_file "$zip_file"; then
    log "ZIP ainda está sendo gravado: $zip_name"
    return 0
  fi

  taskbar_status unzip "$zip_name"
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

  # ZIP de pasta-pai, como orbital.zip, pode conter os ZIPs dos módulos.
  # Primeiro valida todos os ZIPs filhos, sem alterar nenhum projeto. Só depois
  # inicia a importação recursiva. O ZIP pai original permanece em Downloads se
  # qualquer validação ou importação falhar.
  while IFS= read -r -d '' nested_zip; do
    nested_project="$(project_for_zip "$(basename -- "$nested_zip")")"

    [ -n "$nested_project" ] || continue
    [ "$nested_project" != "$project" ] || continue
    [ "${nested_project%/*}" = "$project" ] || continue

    if [ -n "${nested_seen[$nested_project]+x}" ]; then
      log "ERRO: ZIP pai contém mais de um ZIP para o mesmo módulo: $nested_project"
      log "ZIP pai mantido: $zip_file"
      rm -rf -- "$temp_dir"
      return 1
    fi

    if ! unzip -tq "$nested_zip" >/dev/null 2>&1; then
      log "ERRO: ZIP filho inválido: $(basename -- "$nested_zip")"
      log "Nenhum ZIP filho foi importado; ZIP pai mantido: $zip_file"
      rm -rf -- "$temp_dir"
      return 1
    fi

    nested_seen["$nested_project"]=1
    nested_zips+=("$nested_zip")
    nested_projects+=("$nested_project")
  done < <(find "$source_dir" -maxdepth 1 -type f -iname "*.zip" -print0 2>/dev/null)

  nested_count="${#nested_zips[@]}"
  if [ "$nested_count" -gt 0 ]; then
    log "Todos os $nested_count ZIP(s) filho(s) foram validados antes da importação."

    for ((nested_index = 0; nested_index < nested_count; nested_index++)); do
      nested_zip="${nested_zips[$nested_index]}"
      nested_project="${nested_projects[$nested_index]}"
      log "ZIP filho [$((nested_index + 1))/$nested_count]: $(basename -- "$nested_zip") -> $nested_project"

      if ! import_one_zip "$nested_zip" true; then
        log "ERRO: falha ao importar ZIP filho. O ZIP pai foi mantido: $zip_file"
        rm -rf -- "$temp_dir"
        return 1
      fi
    done

    log "$nested_count ZIP(s) filho(s) importado(s) e confirmado(s)."
  fi

  filtered_dir="$(mktemp -d "/tmp/auto-code-unzip-filtered-${archive_name}-XXXXXX")"
  unzip_filter_file="$(mktemp "/tmp/auto-code-unzip-filter-${archive_name}-XXXXXX")"
  make_project_rsync_filter \
    "$IGNORE_UNZIP_FILE" \
    "$project_dir" \
    "auto-code-manager.ignore-unzip" \
    "$unzip_filter_file"

  # Configurações protegidas nunca sobrescrevem o arquivo real. Elas são retiradas
  # do rsync normal e comparadas com a referência sanitizada enviada no backup.
  # Somente arquivos novos ou alterados reaparecem no projeto, com sufixo .external.
  {
    echo "- **/config/local/***"
    echo "- **/config/remote/***"
    echo "- **/config/production/***"
  } >> "$unzip_filter_file"

  log "Protegendo no unzip: */config/local/**, */config/remote/** e */config/production/**"
  log "Aplicando regras de ignore-unzip..."
  if ! rsync -a --filter="merge $unzip_filter_file" -- "$source_dir/" "$filtered_dir/"; then
    log "ERRO: falha ao aplicar ignore-unzip. O ZIP foi mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"
    return 1
  fi

  if ! materialize_changed_protected_configs "$project" "$source_dir" "$filtered_dir"; then
    log "ERRO: falha ao comparar configs protegidos. O ZIP foi mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"
    return 1
  fi

  source_dir="$filtered_dir"
  total_files="$(find "$source_dir" -type f -printf '.' 2>/dev/null | wc -c)"

  if [ "$total_files" -eq 0 ] && [ "$nested_count" -eq 0 ]; then
    log "ERRO: nenhum arquivo foi extraído. O ZIP foi mantido."
    rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"
    return 1
  fi

  if [ "$total_files" -gt 0 ]; then
    log "Arquivos diretos extraídos: $total_files"
    find "$source_dir" -type f -printf '  EXTRAÍDO: %P\n'

    log "Copiando arquivos diretos para o destino..."
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

    log "Todos os $checked_files arquivos diretos foram conferidos no destino."
  else
    log "ZIP pai contém apenas ZIPs filhos; não há arquivos diretos para copiar."
  fi

  rm -rf -- "$temp_dir" "$filtered_dir" "$unzip_filter_file"

  log "Apagando ZIP original somente após todas as confirmações..."

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
  local downloads zip_file
  local total index imported=0 failed=0
  local -a zip_files=()

  downloads="$(downloads_dir)"

  if [ -z "$downloads" ] || [ ! -d "$downloads" ]; then
    log "Downloads não encontrado."
    return 0
  fi

  log "Verificando Downloads: $downloads"

  # Captura todos os ZIPs existentes no início da rodada e os processa no mesmo
  # lote. Assim o monitor não volta para limpeza/backup/espera entre um ZIP e
  # outro. Um arquivo que chegar depois fica para a próxima rodada.
  while IFS= read -r -d '' zip_file; do
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
    log "Nenhum ZIP encontrado em Downloads nesta rodada."
    return 0
  fi

  log "LOTE DE DOWNLOADS: $total ZIP(s) serão processados em sequência antes de continuar o ciclo."

  for ((index = 0; index < total; index++)); do
    zip_file="${zip_files[$index]}"
    log "LOTE [$((index + 1))/$total]: $(basename -- "$zip_file")"

    if import_one_zip "$zip_file"; then
      imported=$((imported + 1))
    else
      failed=$((failed + 1))
      log "Falha ao importar: $(basename -- "$zip_file")"
    fi
  done

  log "LOTE DE DOWNLOADS CONCLUÍDO: $imported sucesso(s), $failed falha(s), $total processado(s)."
  [ "$failed" -eq 0 ]
}

clean_zone() {
  taskbar_status clean "Zone.Identifier"
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

expand_configured_path() {
  local configured_path="$1"

  configured_path="${configured_path/#\~\//$HOME/}"
  configured_path="${configured_path/#\$CODE_ROOT\//$CODE_ROOT/}"
  configured_path="${configured_path/#CODE_ROOT\//$CODE_ROOT/}"

  if [[ "$configured_path" != /* ]]; then
    configured_path="$CODE_ROOT/$configured_path"
  fi

  printf '%s\n' "$configured_path"
}

configured_sql_zip_folders() {
  local raw_line folder

  [ -f "$FOLDER_SQL_ZIP_FILE" ] || return 0

  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    raw_line="${raw_line%$'\r'}"
    raw_line="${raw_line%%#*}"
    raw_line="$(printf '%s' "$raw_line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$raw_line" ] || continue

    folder="$(expand_configured_path "$raw_line")"
    printf '%s\n' "$folder"
  done < "$FOLDER_SQL_ZIP_FILE"
}

zip_sql_folder() {
  local folder="$1"
  local stamp final_zip temp_dir temp_zip sql_file sql_name
  local -a sql_files=()
  local -a sql_names=()

  if [ ! -d "$folder" ]; then
    log "Pasta SQL ainda não existe: $folder"
    return 0
  fi

  while IFS= read -r -d '' sql_file; do
    if stable_file "$sql_file"; then
      sql_files+=("$sql_file")
    else
      log "SQL ainda está sendo gravado: $sql_file"
    fi
  done < <(
    find "$folder" \
      -maxdepth 1 \
      -type f \
      -iname '*.sql' \
      ! -name '*:Zone.Identifier' \
      -print0 2>/dev/null
  )

  [ "${#sql_files[@]}" -gt 0 ] || return 0

  taskbar_status zip "$(basename -- "$folder")"
  stamp="$(date '+%Y%m%d-%H%M')"
  final_zip="$folder/$stamp.zip"
  temp_dir="$(mktemp -d '/tmp/auto-code-folder-sql-zip-XXXXXX')"
  temp_zip="$temp_dir/$stamp.zip"

  if [ -f "$final_zip" ]; then
    if ! unzip -tq "$final_zip" >/dev/null 2>&1; then
      log "ERRO: ZIP existente inválido; SQLs mantidos: $final_zip"
      rm -rf -- "$temp_dir"
      return 1
    fi
    cp -f -- "$final_zip" "$temp_zip" || {
      log "ERRO: não foi possível preparar o ZIP existente: $final_zip"
      rm -rf -- "$temp_dir"
      return 1
    }
  fi

  for sql_file in "${sql_files[@]}"; do
    sql_name="$(basename -- "$sql_file")"
    sql_names+=("$sql_name")
    cp -f -- "$sql_file" "$temp_dir/$sql_name" || {
      log "ERRO: não foi possível preparar o SQL: $sql_file"
      rm -rf -- "$temp_dir"
      return 1
    }
  done

  (
    cd "$temp_dir" || exit 1
    zip -q "$temp_zip" -- "${sql_names[@]}"
  ) || {
    log "ERRO: falha ao gerar ZIP de SQLs em $folder; SQLs mantidos."
    rm -rf -- "$temp_dir"
    return 1
  }

  if [ ! -s "$temp_zip" ] || ! unzip -tq "$temp_zip" >/dev/null 2>&1; then
    log "ERRO: validação do ZIP de SQLs falhou; SQLs mantidos: $folder"
    rm -rf -- "$temp_dir"
    return 1
  fi

  if ! mv -f -- "$temp_zip" "$final_zip"; then
    log "ERRO: não foi possível instalar o ZIP final; SQLs mantidos: $final_zip"
    rm -rf -- "$temp_dir"
    return 1
  fi

  for sql_file in "${sql_files[@]}"; do
    if ! rm -f -- "$sql_file" || [ -e "$sql_file" ]; then
      log "ERRO: ZIP válido, mas o SQL não foi apagado: $sql_file"
      rm -rf -- "$temp_dir"
      return 1
    fi
  done

  rm -rf -- "$temp_dir"
  log "OK SQL ZIP: $final_zip (${#sql_files[@]} arquivo(s)); SQLs apagados."
  return 0
}

zip_configured_sql_folders() {
  local folder failed=0

  while IFS= read -r folder || [ -n "$folder" ]; do
    [ -n "$folder" ] || continue
    zip_sql_folder "$folder" || failed=1
  done < <(configured_sql_zip_folders)

  return "$failed"
}

sanitize_backup_config_passwords() {
  local backup_dir="$1"

  python3 - "$backup_dir" <<'PY_SANITIZE'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
placeholder = "********"
config_extensions = {".env", ".ini", ".conf", ".cfg", ".properties"}
config_names = {"env", ".env", "config", "settings"}
secret_key = re.compile(
    r"(?:^|_)(?:PASSWORD|PASSWD|PWD|SECRET|TOKEN|API_KEY|ACCESS_KEY|PRIVATE_KEY)(?:$|_)",
    re.IGNORECASE,
)
assignment = re.compile(
    r"^(?P<prefix>\s*(?:export\s+)?(?P<key>[A-Za-z_][A-Za-z0-9_.-]*)\s*=\s*)(?P<value>.*?)(?P<ending>\r?\n?)$"
)
url_credentials = re.compile(
    r"(?P<prefix>\b[A-Za-z][A-Za-z0-9+.-]*://[^\s:/@]+:)(?P<password>[^\s@]*)(?P<suffix>@)"
)
changed_files = 0
changed_values = 0


def is_config_file(path: Path) -> bool:
    parts = path.relative_to(root).parts
    if not any(part.lower() == "config" for part in parts[:-1]):
        return False

    name = path.name.lower()
    suffix = path.suffix.lower()
    return (
        suffix in config_extensions
        or name in config_names
        or name.startswith(".env.")
        or name.endswith(".env")
    )


def mask_value(value: str) -> str:
    stripped = value.strip()
    if not stripped:
        return value

    leading = value[: len(value) - len(value.lstrip())]
    trailing = value[len(value.rstrip()) :]
    core = stripped

    comment = ""
    comment_match = re.match(r"^(.*?)(\s+[;#][^\r\n]*)$", core)
    if comment_match:
        core, comment = comment_match.groups()
        core = core.rstrip()

    if len(core) >= 2 and core[0] == core[-1] and core[0] in {"'", '"'}:
        masked = f"{core[0]}{placeholder}{core[-1]}"
    else:
        masked = placeholder

    return f"{leading}{masked}{comment}{trailing}"


for path in root.rglob("*"):
    if not path.is_file() or not is_config_file(path):
        continue

    try:
        raw = path.read_bytes()
    except OSError:
        continue

    if b"\x00" in raw:
        continue

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        continue

    output = []
    file_changed = False

    for line in text.splitlines(keepends=True):
        match = assignment.match(line)
        if not match:
            output.append(line)
            continue

        key = match.group("key")
        value = match.group("value")

        if secret_key.search(key):
            new_value = mask_value(value)
        else:
            new_value = url_credentials.sub(
                lambda item: f"{item.group('prefix')}{placeholder}{item.group('suffix')}",
                value,
            )

        if new_value != value:
            file_changed = True
            changed_values += 1

        output.append(f"{match.group('prefix')}{new_value}{match.group('ending')}")

    if file_changed:
        path.write_text("".join(output), encoding="utf-8", newline="")
        changed_files += 1

print(f"{changed_files}:{changed_values}")
PY_SANITIZE
}

protected_config_relpath() {
  case "$1" in
    */config/local/*|*/config/remote/*|*/config/production/*) return 0 ;;
    *) return 1 ;;
  esac
}

protected_config_baseline_dir() {
  local project="$1"
  printf '%s/%s\n' "$PROTECTED_CONFIG_BASELINES_DIR" "$(project_archive_name "$project")"
}

save_protected_config_baseline() {
  local project="$1"
  local sanitized_root="$2"
  local baseline_dir rel destination

  baseline_dir="$(protected_config_baseline_dir "$project")"
  rm -rf -- "$baseline_dir"
  mkdir -p -- "$baseline_dir"

  while IFS= read -r -d '' rel; do
    protected_config_relpath "$rel" || continue
    destination="$baseline_dir/$rel"
    mkdir -p -- "$(dirname -- "$destination")"
    cp -p -- "$sanitized_root/$rel" "$destination"
  done < <(find "$sanitized_root" -type f -printf '%P\0')
}

materialize_changed_protected_configs() {
  local project="$1"
  local source_root="$2"
  local filtered_root="$3"
  local baseline_dir rel baseline external changed=0 unchanged=0

  baseline_dir="$(protected_config_baseline_dir "$project")"

  while IFS= read -r -d '' rel; do
    protected_config_relpath "$rel" || continue
    baseline="$baseline_dir/$rel"

    if [ -f "$baseline" ] && cmp -s -- "$source_root/$rel" "$baseline"; then
      unchanged=$((unchanged + 1))
      continue
    fi

    external="$filtered_root/$rel.external"
    mkdir -p -- "$(dirname -- "$external")"
    cp -p -- "$source_root/$rel" "$external"
    changed=$((changed + 1))
    log "ENV EXTERNAL: $rel -> $rel.external"
  done < <(find "$source_root" -type f -printf '%P\0')

  log "ENV protegidos: $changed alterado(s)/novo(s), $unchanged sem mudança."
}

backup_project() {
  local project="$1"
  local project_dir
  local archive_name
  local temp_dir
  local temp_zip
  local final_zip
  local filter_file=""
  local child child_name child_zip child_count
  local sanitize_result sanitized_files sanitized_values
  local -a children=()

  project_dir="$(project_path "$project")"
  archive_name="$(project_archive_name "$project")"

  if [ ! -d "$project_dir" ]; then
    log "ERRO: projeto não existe: $project_dir"
    rm -f -- "$(project_archive_path "$project")"
    return 1
  fi

  taskbar_status backup "$archive_name"
  temp_dir="$(mktemp -d "/tmp/auto-code-backup-${archive_name}-XXXXXX")"
  temp_zip="/tmp/${archive_name}-backup-$$.zip"
  final_zip="$(project_archive_path "$project")"
  mapfile -t children < <(direct_child_projects "$project")
  child_count="${#children[@]}"

  log "Gerando backup: $project -> $final_zip"

  if [ "$child_count" -gt 0 ]; then
    # Um agrupador contém exclusivamente os ZIPs dos filhos ativos imediatos.
    # Nenhum arquivo solto ou pasta do agrupador entra no pacote.
    for child in "${children[@]}"; do
      child_name="$(project_archive_name "$child")"
      child_zip="$(project_archive_path "$child")"

      if [ ! -s "$child_zip" ] || ! unzip -tq "$child_zip" >/dev/null 2>&1; then
        log "ERRO: ZIP filho ausente ou inválido para o pacote pai: $child_zip"
        rm -rf -- "$temp_dir" "$temp_zip"
        return 1
      fi

      cp -f -- "$child_zip" "$temp_dir/$child_name.zip" || {
        log "ERRO ao incluir ZIP filho no pacote pai: $child_zip"
        rm -rf -- "$temp_dir" "$temp_zip"
        return 1
      }
    done

    log "Pacote pai preparado somente com $child_count ZIP(s) filho(s)."
  else
    filter_file="$(mktemp "/tmp/auto-code-filter-${archive_name}-XXXXXX")"

    make_project_rsync_filter \
      "$IGNORE_ZIP_FILE" \
      "$project_dir" \
      "auto-code-manager.ignore-zip" \
      "$filter_file"

    if ! rsync -a \
      --filter="merge $filter_file" \
      "$project_dir/" \
      "$temp_dir/"; then

      log "ERRO no rsync do projeto: $project"
      rm -rf -- "$temp_dir" "$filter_file" "$temp_zip"
      return 1
    fi

    if ! sanitize_result="$(sanitize_backup_config_passwords "$temp_dir")"; then
      log "ERRO ao sanitizar senhas dos configs no backup: $project"
      rm -rf -- "$temp_dir" "$filter_file" "$temp_zip"
      return 1
    fi

    sanitized_files="${sanitize_result%%:*}"
    sanitized_values="${sanitize_result##*:}"
    if [ "${sanitized_values:-0}" -gt 0 ]; then
      log "Configs sanitizados no ZIP: ${sanitized_values} senha(s) em ${sanitized_files} arquivo(s)."
    fi

    if ! save_protected_config_baseline "$project" "$temp_dir"; then
      log "ERRO ao salvar referência sanitizada dos configs protegidos: $project"
      rm -rf -- "$temp_dir" "$filter_file" "$temp_zip"
      return 1
    fi
    log "Referência sanitizada dos configs protegidos atualizada."
  fi

  if ! (
    cd "$temp_dir" &&
    zip -qry "$temp_zip" .
  ); then
    log "ERRO ao compactar projeto: $project"
    rm -rf -- "$temp_dir" ${filter_file:+"$filter_file"} "$temp_zip"
    return 1
  fi

  if [ ! -s "$temp_zip" ] || ! unzip -tq "$temp_zip" >/dev/null 2>&1; then
    log "ERRO: validação do backup falhou: $project"
    rm -rf -- "$temp_dir" ${filter_file:+"$filter_file"} "$temp_zip"
    return 1
  fi

  mv -f -- "$temp_zip" "$final_zip"
  rm -rf -- "$temp_dir"
  [ -z "$filter_file" ] || rm -f -- "$filter_file"

  log "OK backup: $final_zip"
  return 0
}

clean_unmanaged_backup_zips() {
  local zip_file expected project managed

  log "Limpando ZIPs de backup fora dos projetos e grupos gerenciados em $CODE_ROOT"

  while IFS= read -r -d '' zip_file; do
    case "$zip_file" in
      "$CODE_ROOT/Code.zip"|"$CODE_ROOT/code.zip") continue ;;
    esac

    managed=false
    while IFS= read -r project || [ -n "$project" ]; do
      [ -n "$project" ] || continue
      expected="$(project_archive_path "$project")"
      if [ "$zip_file" = "$expected" ]; then
        managed=true
        break
      fi
    done < <(backup_targets)

    if [ "$managed" = false ]; then
      log "Removendo ZIP fora do .projects: $zip_file"
      rm -f -- "$zip_file" || log "ERRO ao remover ZIP fora do .projects: $zip_file"
    fi
  done < <(
    find "$CODE_ROOT" -mindepth 1 -maxdepth 3 -type f -iname "*.zip" -print0 2>/dev/null
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
    project_zip="$(project_archive_path "$project")"

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
  done < <(backup_targets)

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
  done < <(backup_targets)

  if [ "$failed" -ne 0 ]; then
    log "ERRO: um ou mais projetos falharam; Code.zip anterior foi mantido; o novo não foi criado neste ciclo."
    return 1
  fi

  log "Todos os projetos e grupos pais foram compactados; chamando create_code_zip agora."
  if ! create_code_zip; then
    return 1
  fi

  log "Rodada completa de backup concluída."
  return 0
}

stop() {
  taskbar_status exit "Auto Code Manager encerrado"
  echo
  line
  echo "Encerrado."
  exit 0
}

trap stop INT TERM

ensure_files
load_env
validate_timers

if [ "${1:-}" = "--test-sound" ]; then
  soft_beep
  exit $?
fi

if [ "${1:-}" = "--test-backup-sound" ]; then
  backup_beep
  exit $?
fi

if [ "${1:-}" = "--list-backup-targets" ]; then
  backup_targets
  exit 0
fi

if [ "${1:-}" = "--identify-zip" ]; then
  if [ -z "${2:-}" ]; then
    echo "Uso: auto-code-manager --identify-zip <arquivo.zip>" >&2
    exit 2
  fi

  identified_project="$(project_for_zip "$(basename -- "$2")")"
  if [ -z "$identified_project" ]; then
    echo "NÃO RECONHECIDO: $(basename -- "$2")" >&2
    exit 1
  fi

  echo "$identified_project"
  exit 0
fi

if [ "${1:-}" = "--import-downloads-once" ]; then
  if [ ! -d "$CODE_ROOT" ]; then
    echo "ERRO: diretório não existe: $CODE_ROOT" >&2
    exit 1
  fi

  if ! validate_projects; then
    echo "ERRO: corrija $PROJECTS_FILE antes de importar." >&2
    exit 1
  fi

  if import_downloads; then
    taskbar_status done "Importação concluída"
    exit 0
  fi
  taskbar_status error "Falha na importação"
  exit 1
fi

if [ "${1:-}" = "--import-one" ]; then
  if [ -z "${2:-}" ]; then
    echo "Uso: auto-code-manager --import-one <arquivo.zip>" >&2
    exit 2
  fi

  if [ ! -d "$CODE_ROOT" ]; then
    echo "ERRO: diretório não existe: $CODE_ROOT" >&2
    exit 1
  fi

  if ! validate_projects; then
    echo "ERRO: corrija $PROJECTS_FILE antes de importar." >&2
    exit 1
  fi

  taskbar_status unzip "Importando $(basename -- "$2")"
  if import_one_zip "$2"; then
    taskbar_status done "Importação concluída"
    exit 0
  fi
  taskbar_status error "Falha na importação"
  exit 1
fi

if [ "${1:-}" = "--sql-zip-once" ]; then
  if [ ! -d "$CODE_ROOT" ]; then
    echo "ERRO: diretório não existe: $CODE_ROOT" >&2
    exit 1
  fi

  if zip_configured_sql_folders; then
    taskbar_status done "SQLs compactados"
    exit 0
  fi
  taskbar_status error "Falha ao compactar SQLs"
  exit 1
fi

if [ ! -d "$CODE_ROOT" ]; then
  echo "ERRO: diretório não existe: $CODE_ROOT" >&2
  exit 1
fi

if ! validate_projects; then
  echo "ERRO: corrija $PROJECTS_FILE antes de iniciar." >&2
  exit 1
fi

if [ "${1:-}" = "--backup-once" ]; then
  taskbar_status backup "Backup manual"
  if zip_configured_sql_folders && clean_unmanaged_backup_zips && backup_all; then
    taskbar_status done "Backup concluído"
    exit 0
  fi
  taskbar_status error "Falha no backup"
  exit 1
fi

line
echo "Auto Code Manager - $SCRIPT_VERSION"
line
echo "CODE_ROOT:     $CODE_ROOT"
echo "Downloads:     $(downloads_dir)"
echo "ENV:           $ENV_FILE"
echo "SQL ZIP:       $FOLDER_SQL_ZIP_FILE"
echo "Intervalo:     ${INTERVAL}s"
echo "Backup cada:   ${BACKUP_EVERY}s"
echo "Zone cada:     ${ZONE_EVERY}s"
echo "Estável por:   ${STABLE_WAIT}s"
line

cycle=1
last_backup=0
last_zone=0
taskbar_status idle "Monitorando"

while true; do
  now="$(date +%s)"

  stage cycle start "CICLO #$cycle — INÍCIO" "Executa, nesta ordem: importar ZIPs, compactar SQLs, limpar Zone.Identifier quando devido e gerar backups quando devidos."

  run_stage downloads "DOWNLOADS / IMPORTAÇÃO" "Procura ZIPs em Downloads, identifica o projeto correspondente e importa cada pacote com segurança." import_downloads || true
  run_stage sql "SQL → ZIP" "Procura arquivos .sql nas pastas configuradas, cria o ZIP YYYYMMDD-HHMM.zip, valida e só então apaga os SQLs incluídos." zip_configured_sql_folders || true

  if [ $((now - last_zone)) -ge "$ZONE_EVERY" ]; then
    run_stage zone "LIMPEZA ZONE.IDENTIFIER" "Remove arquivos residuais :Zone.Identifier existentes dentro de $CODE_ROOT." clean_zone || true
    last_zone="$now"
  else
    stage zone skip "ZONE.IDENTIFIER — AINDA NÃO VENCEU" "Nenhuma limpeza agora; será executada quando completar o intervalo de ${ZONE_EVERY}s."
  fi

  if [ $((now - last_backup)) -ge "$BACKUP_EVERY" ]; then
    taskbar_status backup "Gerando backups"
    stage backup start "BACKUP — INÍCIO" "Gera os ZIPs dos projetos autorizados e, ao final, atualiza o Code.zip geral."
    LOG_CONTEXT=backup clean_unmanaged_backup_zips
    if LOG_CONTEXT=backup backup_all; then
      LOG_CONTEXT=backup log "Ciclo de backup concluído com Code.zip."
      stage backup end "BACKUP — CONCLUÍDO"
    else
      taskbar_status error "Backup falhou"
      LOG_CONTEXT=error log "ERRO: ciclo de backup terminou sem Code.zip."
    fi
    last_backup="$now"
  else
    stage wait skip "BACKUP — AINDA NÃO VENCEU" "Nenhum backup agora; será executado quando completar o intervalo de ${BACKUP_EVERY}s."
  fi

  taskbar_status idle "Monitorando"
  stage cycle end "CICLO #$cycle — CONCLUÍDO"
  LOG_CONTEXT=wait log "Próximo ciclo em ${INTERVAL}s."

  cycle=$((cycle + 1))
  sleep "$INTERVAL"
done
