#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# auto-code-manager.sh
#
# Script único para /home/daniel/Code.
#
# Faz:
# 1) Monitora Downloads do Windows.
# 2) Move ZIPs para o projeto correto pelo nome inicial do arquivo.
# 3) Descompacta sobrescrevendo arquivos.
# 4) Apaga o ZIP importado depois de extrair.
# 5) Limpa arquivos *:Zone.Identifier.
# 6) Gera backup ZIP de cada projeto direto em /home/daniel/Code.
# 7) O backup tem apenas o nome do projeto e sobrescreve o anterior.
# 8) Usa o .gitignore de cada projeto como lista simples de exclusão.
#
# Exemplo importação:
#   site-inst.zip             -> /home/daniel/Code/site-inst
#   site-inst-ajuste.zip      -> /home/daniel/Code/site-inst
#   general-crawler-fix.zip   -> /home/daniel/Code/general-crawler
#
# Exemplo backup:
#   /home/daniel/Code/site-inst.zip
#   /home/daniel/Code/general-crawler.zip
# -----------------------------------------------------------------------------

CODE_ROOT="/home/daniel/Code"
BACKUP_ROOT="/home/daniel/Code"

INTERVAL_SECONDS=6
BACKUP_EVERY_SECONDS=300
ZONE_EVERY_SECONDS=30
STABLE_WAIT_SECONDS=2

WATCH_DOWNLOADS=1
CLEAN_ZONE_IDENTIFIER=1
CREATE_BACKUPS=1
VERBOSE=1

EXCLUDED_PROJECTS=(
  ".backups"
  ".cache"
  ".idea"
)

log() {
  if [ "$VERBOSE" = "1" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  fi
}

warn() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] AVISO: $*" >&2
}

line() {
  echo "────────────────────────────────────────────────────────────"
}

format_seconds() {
  local seconds="$1"
  local minutes rest

  [ "$seconds" -lt 0 ] && seconds=0

  minutes=$((seconds / 60))
  rest=$((seconds % 60))

  printf '%02d:%02d' "$minutes" "$rest"
}

is_excluded_project() {
  local name="$1"
  local item

  for item in "${EXCLUDED_PROJECTS[@]}"; do
    [ "$name" = "$item" ] && return 0
  done

  return 1
}

downloads_dir() {
  local win_profile=""
  local wsl_profile=""

  if command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
    win_profile="$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r' || true)"

    if [ -n "$win_profile" ]; then
      wsl_profile="$(wslpath "$win_profile" 2>/dev/null || true)"

      if [ -d "$wsl_profile/Downloads" ]; then
        echo "$wsl_profile/Downloads"
        return 0
      fi
    fi
  fi

  if [ -d "/mnt/c/Users/${USER}/Downloads" ]; then
    echo "/mnt/c/Users/${USER}/Downloads"
    return 0
  fi

  echo ""
}

stable_file() {
  local file="$1"
  local size1 size2

  [ -f "$file" ] || return 1

  size1="$(stat -c %s "$file" 2>/dev/null || echo 0)"
  sleep "$STABLE_WAIT_SECONDS"

  [ -f "$file" ] || return 1

  size2="$(stat -c %s "$file" 2>/dev/null || echo 0)"

  [ "$size1" = "$size2" ] && [ "$size1" -gt 0 ]
}

list_projects() {
  find "$CODE_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

project_for_zip() {
  local zip_name="$1"
  local project=""
  local best=""

  while IFS= read -r project; do
    is_excluded_project "$project" && continue

    # Aceita:
    #   site-inst.zip
    #   site-inst-alguma-coisa.zip
    #   site-inst_alguma_coisa.zip
    #
    # Não aceita:
    #   meusite-inst.zip
    if [[ "$zip_name" == "$project.zip" || "$zip_name" == "$project"-*.zip || "$zip_name" == "$project"_*.zip ]]; then
      if [ ${#project} -gt ${#best} ]; then
        best="$project"
      fi
    fi
  done < <(list_projects)

  echo "$best"
}

import_downloads_once() {
  [ "$WATCH_DOWNLOADS" = "1" ] || return 0

  local dl
  local found=0
  local imported=0
  local ignored=0

  dl="$(downloads_dir)"

  if [ -z "$dl" ] || [ ! -d "$dl" ]; then
    warn "Downloads não encontrado."
    return 0
  fi

  log "Verificando Downloads: $dl"

  while IFS= read -r -d '' zip_file; do
    local zip_name project project_dir target_zip

    found=$((found + 1))

    zip_name="$(basename "$zip_file")"
    project="$(project_for_zip "$zip_name")"

    if [ -z "$project" ]; then
      log "Ignorando ZIP sem projeto correspondente: $zip_name"
      ignored=$((ignored + 1))
      continue
    fi

    project_dir="$CODE_ROOT/$project"
    target_zip="$project_dir/$zip_name"

    if [ ! -d "$project_dir" ]; then
      warn "Projeto detectado, mas pasta não existe: $project_dir"
      ignored=$((ignored + 1))
      continue
    fi

    if ! stable_file "$zip_file"; then
      log "Ainda baixando/gravando, fica para o próximo ciclo: $zip_name"
      ignored=$((ignored + 1))
      continue
    fi

    if ! command -v unzip >/dev/null 2>&1; then
      warn "unzip não encontrado. Instale com: sudo apt install -y unzip"
      return 1
    fi

    log "Importando ZIP:"
    log "  Arquivo: $zip_name"
    log "  Projeto: $project"
    log "  Destino: $project_dir"

    mv -f -- "$zip_file" "$target_zip"

    unzip -oq -- "$target_zip" -d "$project_dir"

    rm -f -- "$target_zip"

    log "OK importado e extraído: $zip_name"

    imported=$((imported + 1))
  done < <(find "$dl" -maxdepth 1 -type f -iname "*.zip" -print0 2>/dev/null)

  log "Resumo Downloads: encontrados=$found, importados=$imported, ignorados/aguardando=$ignored"
}

clean_zone_once() {
  [ "$CLEAN_ZONE_IDENTIFIER" = "1" ] || return 0

  local removed=0

  log "Limpando Zone.Identifier em: $CODE_ROOT"

  while IFS= read -r -d '' file; do
    log "  Apagando: $file"
    rm -f -- "$file"
    removed=$((removed + 1))
  done < <(find "$CODE_ROOT" -type f -name "*:Zone.Identifier" -print0 2>/dev/null)

  log "Resumo Zone.Identifier: apagados=$removed"
}

build_exclude_file() {
  local project_dir="$1"
  local output_file="$2"
  local gitignore="$project_dir/.gitignore"

  rm -f -- "$output_file"
  touch "$output_file"

  # Exclusões obrigatórias.
  {
    echo ".git/"
    echo "*.zip"
    echo "*.log"
    echo "*:Zone.Identifier"
  } >> "$output_file"

  # Usa o .gitignore como lista simples.
  if [ -f "$gitignore" ]; then
    grep -vE '^[[:space:]]*$|^[[:space:]]*#' "$gitignore" >> "$output_file" || true
  fi
}

backup_project_once() {
  local project_dir="$1"
  local project_name tmp_dir final_zip exclude_file tmp_zip

  project_name="$(basename "$project_dir")"

  is_excluded_project "$project_name" && {
    log "Pulando pasta excluída: $project_name"
    return 0
  }

  [ -d "$project_dir" ] || return 0

  if ! command -v rsync >/dev/null 2>&1; then
    warn "rsync não encontrado. Instale com: sudo apt install -y rsync"
    return 1
  fi

  if ! command -v zip >/dev/null 2>&1; then
    warn "zip não encontrado. Instale com: sudo apt install -y zip"
    return 1
  fi

  tmp_dir="/tmp/${project_name}-backup-$$"
  exclude_file="/tmp/${project_name}-exclude-$$.txt"
  final_zip="$BACKUP_ROOT/${project_name}.zip"
  tmp_zip="$BACKUP_ROOT/.${project_name}.zip.tmp"

  rm -rf -- "$tmp_dir"
  rm -f -- "$tmp_zip"
  mkdir -p "$tmp_dir"

  build_exclude_file "$project_dir" "$exclude_file"

  log "Gerando backup:"
  log "  Projeto: $project_name"
  log "  Origem:  $project_dir"
  log "  ZIP:     $final_zip"
  log "  Regra:   sobrescreve o backup anterior"

  rsync -a \
    --exclude-from="$exclude_file" \
    "$project_dir/" "$tmp_dir/"

  (
    cd "$tmp_dir"
    zip -qr "$tmp_zip" .
  )

  mv -f -- "$tmp_zip" "$final_zip"

  rm -rf -- "$tmp_dir" "$exclude_file"

  local size_bytes
  size_bytes="$(stat -c %s "$final_zip" 2>/dev/null || echo 0)"

  log "Backup concluído:"
  log "  $final_zip"
  log "  Tamanho: $size_bytes bytes"
}

backup_all_once() {
  [ "$CREATE_BACKUPS" = "1" ] || return 0

  local total=0
  local done_count=0
  local skipped=0
  local project_dir

  log "Iniciando backups em: $BACKUP_ROOT"

  for project_dir in "$CODE_ROOT"/*; do
    [ -d "$project_dir" ] || continue

    total=$((total + 1))

    if backup_project_once "$project_dir"; then
      done_count=$((done_count + 1))
    else
      skipped=$((skipped + 1))
    fi
  done

  log "Resumo backups: projetos=$total, concluídos=$done_count, erro/pulados=$skipped"
}

stop() {
  echo
  line
  echo "Monitoramento encerrado."
  exit 0
}

trap stop INT TERM

if [ ! -d "$CODE_ROOT" ]; then
  echo "ERRO: CODE_ROOT não existe: $CODE_ROOT" >&2
  exit 1
fi

DOWNLOADS_DETECTED="$(downloads_dir)"

line
echo "Auto Code Manager iniciado"
line
echo "CODE_ROOT:              $CODE_ROOT"
echo "BACKUP_ROOT:            $BACKUP_ROOT"
echo "Downloads detectado:    ${DOWNLOADS_DETECTED:-não encontrado}"
echo "Intervalo geral:        ${INTERVAL_SECONDS}s"
echo "Backup a cada:          ${BACKUP_EVERY_SECONDS}s ($(format_seconds "$BACKUP_EVERY_SECONDS"))"
echo "Zone.Identifier a cada: ${ZONE_EVERY_SECONDS}s ($(format_seconds "$ZONE_EVERY_SECONDS"))"
echo "Usa Git:                NÃO"
echo "Usa .gitignore:         SIM, como lista simples de exclusão"
echo "Regra importação:       nome-do-projeto.zip ou nome-do-projeto-*.zip"
echo "Formato backups:        /home/daniel/Code/nome-do-projeto.zip"
echo "Sobrescreve backup:     SIM"
echo "Para parar:             Ctrl+C"
line

cycle=1
last_backup_ts=0
last_zone_ts=0

while true; do
  now_ts="$(date +%s)"

  line
  log "Ciclo #$cycle iniciado."

  import_downloads_once

  if [ $((now_ts - last_zone_ts)) -ge "$ZONE_EVERY_SECONDS" ]; then
    clean_zone_once
    last_zone_ts="$now_ts"
  else
    remaining=$((ZONE_EVERY_SECONDS - (now_ts - last_zone_ts)))
    log "Zone.Identifier ainda não venceu. Falta aproximadamente $(format_seconds "$remaining")."
  fi

  if [ $((now_ts - last_backup_ts)) -ge "$BACKUP_EVERY_SECONDS" ]; then
    backup_all_once
    last_backup_ts="$now_ts"
  else
    remaining=$((BACKUP_EVERY_SECONDS - (now_ts - last_backup_ts)))
    log "Backup ainda não venceu. Falta aproximadamente $(format_seconds "$remaining")."
  fi

  log "Ciclo #$cycle finalizado. Próximo ciclo em $(format_seconds "$INTERVAL_SECONDS")."

  cycle=$((cycle + 1))
  sleep "$INTERVAL_SECONDS"
done