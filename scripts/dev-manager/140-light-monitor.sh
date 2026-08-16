#!/usr/bin/env bash
# Contexto: plano e ciclos do monitor leve sem inotify

watch_root_projects() {
  local project parent project_dir
  declare -A seen=()

  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    target_is_aggregate "$project" && continue

    parent="$(registered_parent_project "$project")"
    [ -z "$parent" ] || continue

    project_dir="$(project_path "$project")"
    # Catálogo pode conter projetos ainda não instalados nesta máquina.
    # Não passe caminhos inexistentes ao watcher.
    [ -d "$project_dir" ] || continue
    if [ -z "${seen[$project_dir]+x}" ]; then
      printf '%s\n' "$project_dir"
      seen["$project_dir"]=1
    fi
  done < <(backup_targets)
}


light_config_signature() {
  local path
  for path in "$ENV_FILE" "$PROJECTS_FILE" "$IGNORE_ZIP_FILE" "$FOLDER_SQL_ZIP_FILE"; do
    if [ -e "$path" ]; then
      stat -c '%n\t%Y\t%s' -- "$path" 2>/dev/null || true
    else
      printf '%s\tmissing\n' "$path"
    fi
  done
}

build_light_watch_plan() {
  local project root child child_root excluded
  local -a projects=()

  mkdir -p "$STATE_DIR"
  LIGHT_WATCH_PLAN="$STATE_DIR/light-watch-plan.tsv"
  : > "$LIGHT_WATCH_PLAN"

  mapfile -t projects < <(backup_targets)
  for project in "${projects[@]}"; do
    [ -n "$project" ] || continue
    target_is_aggregate "$project" && continue
    root="$(project_path "$project")"
    [ -d "$root" ] || continue

    printf 'P\t%s\t%s\n' "$project" "$root" >> "$LIGHT_WATCH_PLAN"

    # Mesmas subárvores pesadas já ignoradas pelo backup/.gitignore.
    while IFS= read -r excluded || [ -n "$excluded" ]; do
      [ -n "$excluded" ] || continue
      printf 'X\t%s\t%s\n' "$project" "$excluded" >> "$LIGHT_WATCH_PLAN"
    done < <(watch_excluded_directories "$root")

    # Se um alvo configurado está dentro de outro, o pai não percorre o filho:
    # cada subprojeto é medido uma vez e recebe o próprio backup.
    for child in "${projects[@]}"; do
      [ "$child" = "$project" ] && continue
      [ -n "$child" ] || continue
      target_is_aggregate "$child" && continue
      child_root="$(project_path "$child")"
      if [ "$child_root" != "$root" ] && path_is_within_absolute "$child_root" "$root"; then
        printf 'X\t%s\t%s\n' "$project" "$child_root" >> "$LIGHT_WATCH_PLAN"
      fi
    done
  done
}

light_scan_states() {
  [ -n "$LIGHT_WATCH_PLAN" ] && [ -f "$LIGHT_WATCH_PLAN" ] || build_light_watch_plan

  python3 - "$LIGHT_WATCH_PLAN" "$IGNORE_ZIP_FILE" <<'PY_LIGHT_SCAN'
import fnmatch
import hashlib
import os
import sys

plan_file, ignore_file = sys.argv[1:3]
projects = []
excluded = {}

with open(plan_file, 'r', encoding='utf-8', errors='replace') as fh:
    for raw in fh:
        parts = raw.rstrip('\n').split('\t', 2)
        if len(parts) != 3:
            continue
        kind, project, path = parts
        path = os.path.abspath(path)
        if kind == 'P':
            projects.append((project, path))
            excluded.setdefault(project, set())
        elif kind == 'X':
            excluded.setdefault(project, set()).add(path)

file_rules = []
dir_rules = []
try:
    with open(ignore_file, 'r', encoding='utf-8', errors='replace') as fh:
        for raw in fh:
            line = raw.rstrip('\r\n')
            line = line.split('#', 1)[0].strip()
            if not line:
                continue
            negated = line.startswith('!')
            if negated:
                line = line[1:]
            line = line.lstrip('/')
            if not line:
                continue
            if line.endswith('/'):
                line = line[:-1]
                if line:
                    dir_rules.append((negated, line))
            else:
                file_rules.append((negated, line))
except OSError:
    pass


def match_rule(rel, name, pattern):
    if '/' in pattern:
        return fnmatch.fnmatchcase(rel, pattern)
    return fnmatch.fnmatchcase(name, pattern)


def ignored_by_rules(rel, name, rules):
    ignored = False
    for negated, pattern in rules:
        if match_rule(rel, name, pattern):
            ignored = not negated
    return ignored


for project, root in projects:
    fingerprint = hashlib.blake2b(digest_size=16)
    entries = 0
    max_dir_mtime = 0
    dir_count = 0
    max_gitignore_mtime = 0
    gitignore_count = 0
    gitignore_size = 0
    excluded_roots = excluded.get(project, set())

    try:
        st = os.stat(root, follow_symlinks=False)
        max_dir_mtime = max(max_dir_mtime, st.st_mtime_ns)
        dir_count += 1
    except OSError:
        print(f'{project}\tmissing\tmissing\tmissing')
        continue

    for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
        kept = []
        for name in dirs:
            full = os.path.abspath(os.path.join(current, name))
            rel = os.path.relpath(full, root).replace(os.sep, '/')
            if full in excluded_roots or ignored_by_rules(rel, name, dir_rules):
                continue
            kept.append(name)
            try:
                st = os.stat(full, follow_symlinks=False)
            except OSError:
                continue
            max_dir_mtime = max(max_dir_mtime, st.st_mtime_ns)
            entries += 1
            dir_count += 1
            fingerprint.update(b'D\0')
            fingerprint.update(rel.encode('utf-8', errors='surrogateescape'))
            fingerprint.update(b'\0')
            fingerprint.update(str(st.st_mode).encode())
            fingerprint.update(b'\n')
        dirs[:] = kept

        for name in files:
            full = os.path.join(current, name)
            rel = os.path.relpath(full, root).replace(os.sep, '/')
            if ignored_by_rules(rel, name, file_rules):
                continue
            try:
                st = os.stat(full, follow_symlinks=False)
            except OSError:
                continue
            entries += 1
            fingerprint.update(b'F\0')
            fingerprint.update(rel.encode('utf-8', errors='surrogateescape'))
            fingerprint.update(b'\0')
            fingerprint.update(str(st.st_mtime_ns).encode())
            fingerprint.update(b'\0')
            fingerprint.update(str(st.st_size).encode())
            fingerprint.update(b'\0')
            fingerprint.update(str(st.st_mode).encode())
            fingerprint.update(b'\n')
            if name == '.gitignore':
                max_gitignore_mtime = max(max_gitignore_mtime, st.st_mtime_ns)
                gitignore_count += 1
                gitignore_size += st.st_size

    state_sig = f'{fingerprint.hexdigest()}:{entries}'
    tree_sig = f'{max_dir_mtime}:{dir_count}'
    ignore_sig = f'{max_gitignore_mtime}:{gitignore_count}:{gitignore_size}'
    print(f'{project}\t{state_sig}\t{tree_sig}\t{ignore_sig}')
PY_LIGHT_SCAN
}

initialize_light_monitor() {
  local project signature tree_signature ignore_signature

  build_light_watch_plan
  LIGHT_SIGNATURES=()
  LIGHT_TREE_SIGNATURES=()
  LIGHT_IGNORE_SIGNATURES=()
  while IFS=$'\t' read -r project signature tree_signature ignore_signature || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    LIGHT_SIGNATURES["$project"]="$signature"
    LIGHT_TREE_SIGNATURES["$project"]="$tree_signature"
    LIGHT_IGNORE_SIGNATURES["$project"]="$ignore_signature"
  done < <(light_scan_states)

  LIGHT_CONFIG_SIGNATURE="$(light_config_signature)"
  ACTIVE_MONITOR_MODE="light"
  log "Monitor leve ativo: sem inotify; verifica somente metadados dos projetos a cada ${LIGHT_SCAN_INTERVAL}s e poda .gitignore/ignore-zip."
}

light_refresh_if_config_changed() {
  local signature
  signature="$(light_config_signature)"
  [ "$signature" = "$LIGHT_CONFIG_SIGNATURE" ] && return 0

  load_env
  validate_timers
  validate_projects || return 1
  validate_backup_ignore_zip || return 1
  clean_unmanaged_backup_zips || true
  initialize_light_monitor
  mark_all_projects_dirty
  zip_configured_sql_folders || true
  return 0
}

light_process_downloads_and_sql() {
  local downloads folder

  downloads="$(worker_from_dir)"
  if configured_worker_from_zip_exists; then
    run_stage downloads "DOWNLOAD / IMPORTAÇÃO" "ZIP cadastrado no .projects detectado no monitor leve; ignora todos os demais ZIPs de worker/from." \
      import_worker_from || true
  fi

  while IFS= read -r folder || [ -n "$folder" ]; do
    [ -n "$folder" ] || continue
    [ -d "$folder" ] || continue
    if find "$folder" -maxdepth 1 -type f -iname '*.sql' ! -name '*:Zone.Identifier' -print -quit 2>/dev/null | grep -q .; then
      run_stage sql "SQL → ZIP" "SQL detectado no monitor leve; compacta somente a pasta afetada." \
        zip_sql_folder "$folder" || true
    fi
  done < <(configured_sql_zip_folders)
}

light_scan_cycle() {
  local project signature tree_signature ignore_signature old old_tree old_ignore scan_file
  local plan_changed=false

  light_refresh_if_config_changed || return 1
  light_process_downloads_and_sql

  scan_file="$(mktemp "$STATE_DIR/light-scan-XXXXXX")" || return 1
  if ! light_scan_states > "$scan_file"; then
    rm -f -- "$scan_file"
    return 1
  fi

  # Mudança estrutural pede nova poda antes de decidir se o projeto realmente
  # mudou. Assim uma pasta nova já ignorada pelo .gitignore não gera backup
  # falso só porque o diretório pai teve o mtime alterado.
  while IFS=$'\t' read -r project signature tree_signature ignore_signature || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    old_tree="${LIGHT_TREE_SIGNATURES[$project]-}"
    old_ignore="${LIGHT_IGNORE_SIGNATURES[$project]-}"
    if { [ -n "$old_tree" ] && [ "$old_tree" != "$tree_signature" ]; } || \
       { [ -n "$old_ignore" ] && [ "$old_ignore" != "$ignore_signature" ]; }; then
      plan_changed=true
      break
    fi
  done < "$scan_file"

  if [ "$plan_changed" = true ]; then
    build_light_watch_plan
    if ! light_scan_states > "$scan_file"; then
      rm -f -- "$scan_file"
      return 1
    fi
  fi

  while IFS=$'\t' read -r project signature tree_signature ignore_signature || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    old="${LIGHT_SIGNATURES[$project]-}"
    if [ -n "$old" ] && [ "$old" != "$signature" ]; then
      mark_backup_dirty "$project"
    fi
    LIGHT_SIGNATURES["$project"]="$signature"
    LIGHT_TREE_SIGNATURES["$project"]="$tree_signature"
    LIGHT_IGNORE_SIGNATURES["$project"]="$ignore_signature"
  done < "$scan_file"

  rm -f -- "$scan_file"
  return 0
}

start_change_monitor() {
  case "${AUTO_CODE_MONITOR_MODE:-light}" in
    light)
      initialize_light_monitor
      ;;
    inotify)
      start_backup_watcher || return 1
      ACTIVE_MONITOR_MODE="inotify"
      ;;
    auto)
      if start_backup_watcher; then
        ACTIVE_MONITOR_MODE="inotify"
      else
        LOG_CONTEXT=wait log "Inotify indisponível; usando monitor leve sem aumentar fs.inotify.max_user_instances."
        initialize_light_monitor
      fi
      ;;
    *)
      log "ERRO: AUTO_CODE_MONITOR_MODE deve ser light, inotify ou auto. Valor: ${AUTO_CODE_MONITOR_MODE:-}"
      return 1
      ;;
  esac
}

