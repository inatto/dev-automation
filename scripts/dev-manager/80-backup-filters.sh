#!/usr/bin/env bash
# Contexto: limpeza Zone.Identifier e filtros rsync de backup

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

