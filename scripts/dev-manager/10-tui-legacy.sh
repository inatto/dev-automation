#!/usr/bin/env bash
# Contexto: fallback TUI ANSI legado quando ncurses não estiver disponível

tui_supported() {
  [ "${AUTO_CODE_TUI:-clipper}" != "off" ] || return 1
  [ -t 1 ] || return 1
  [ "${TERM:-dumb}" != "dumb" ] || return 1
  return 0
}

tui_terminal_size() {
  local rows cols
  rows="$(tput lines 2>/dev/null || printf '24')"
  cols="$(tput cols 2>/dev/null || printf '80')"
  [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  printf '%s %s\n' "$rows" "$cols"
}

tui_repeat() {
  local char="$1" count="$2" out=""
  local i
  for ((i=0; i<count; i++)); do out+="$char"; done
  printf '%s' "$out"
}

tui_fit() {
  local text="$1" width="$2"
  text="${text//$'\n'/ }"
  text="${text//$'\r'/ }"
  if [ "${#text}" -gt "$width" ]; then
    if [ "$width" -gt 1 ]; then
      text="${text:0:$((width-1))}…"
    else
      text="${text:0:$width}"
    fi
  fi
  printf '%-*s' "$width" "$text"
}

tui_border_text() {
  local left="$1" right="$2" label="${3:-}"
  local inner=$((TUI_COLS - 2)) body=""
  [ "$inner" -gt 0 ] || return 0
  if [ -n "$label" ]; then
    label=" $label "
    if [ "${#label}" -gt "$inner" ]; then
      label="${label:0:$inner}"
    fi
    body="$label$(tui_repeat '═' $((inner-${#label})))"
  else
    body="$(tui_repeat '═' "$inner")"
  fi
  printf '%s%s%s' "$left" "$body" "$right"
}

tui_write_row() {
  local row="$1" color="$2" text="$3"
  local fitted
  fitted="$(tui_fit "$text" "$TUI_COLS")"
  printf '\033[%s;1H\033[%sm%s\033[0m' "$row" "$color" "$fitted"
}

tui_write_box_row() {
  local row="$1" text="$2" color="${3:-44;97}"
  local inner=$((TUI_COLS - 4))
  [ "$inner" -gt 0 ] || return 0
  tui_write_row "$row" "$color" "║ $(tui_fit "$text" "$inner") ║"
}

tui_write_split_row() {
  local row="$1" left="$2" right="$3" color="${4:-44;97}"
  local usable=$((TUI_COLS - 7)) left_width right_width
  [ "$usable" -gt 4 ] || return 0
  left_width=$((usable / 2))
  right_width=$((usable - left_width))
  tui_write_row "$row" "$color" "║ $(tui_fit "$left" "$left_width") │ $(tui_fit "$right" "$right_width") ║"
}

tui_state_label() {
  case "$1" in
    sync|cycle) printf 'SINCRONIZANDO' ;;
    unzip) printf 'IMPORTANDO' ;;
    zip) printf 'SQL → ZIP' ;;
    clean) printf 'LIMPANDO' ;;
    backup) printf 'BACKUP' ;;
    idle) printf 'ATIVO' ;;
    error) printf 'ERRO' ;;
    paused) printf 'PAUSADO' ;;
    done) printf 'OK' ;;
    exit) printf 'SAINDO' ;;
    *) printf '%s' "${1^^}" ;;
  esac
}

tui_collect_metrics() {
  local now downloads info watches count
  local -a inotify_fds=()
  local -a fdinfo_files=()

  now="$(date +%s)"
  if [ "$TUI_METRIC_TS" -gt 0 ] && [ $((now - TUI_METRIC_TS)) -lt 10 ]; then
    return 0
  fi
  TUI_METRIC_TS="$now"

  TUI_INOTIFY_MAX_INSTANCES="$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || printf '0')"
  TUI_INOTIFY_MAX_WATCHES="$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || printf '0')"
  TUI_MANAGER_FD_LIMIT="$(ulimit -n 2>/dev/null || printf '0')"
  TUI_MANAGER_FDS="$(find "/proc/$$/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"

  # Uso real do usuário, sem criar watcher e sem varrer conteúdo dos projetos.
  # find resolve os symlinks /proc em C; mesmo com muitas instâncias é barato.
  mapfile -t inotify_fds < <(
    find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -type l -uid "$(id -u)" \
      -lname 'anon_inode:*inotify*' -print 2>/dev/null || true
  )
  TUI_INOTIFY_INSTANCES="${#inotify_fds[@]}"
  TUI_INOTIFY_WATCHES=0
  if [ "${#inotify_fds[@]}" -gt 0 ]; then
    for info in "${inotify_fds[@]}"; do
      info="${info/\/fd\//\/fdinfo\/}"
      [ -r "$info" ] && fdinfo_files+=("$info")
    done
    if [ "${#fdinfo_files[@]}" -gt 0 ]; then
      watches="$(grep -h '^inotify ' "${fdinfo_files[@]}" 2>/dev/null | wc -l | tr -d ' ')"
      [[ "$watches" =~ ^[0-9]+$ ]] && TUI_INOTIFY_WATCHES="$watches"
    fi
  fi

  TUI_PROJECT_COUNT="$(backup_targets 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  TUI_ZIP_COUNT="$(find "$(archive_output_dir)" -maxdepth 1 -type f -iname '*.zip' 2>/dev/null | wc -l | tr -d ' ')"
  TUI_DOWNLOAD_ZIPS=0
  while IFS= read -r downloads || [ -n "$downloads" ]; do
    [ -n "$downloads" ] || continue
    if [ -d "$downloads" ]; then
      count="$(find "$downloads" -maxdepth 1 -type f -iname '*.zip' 2>/dev/null | wc -l | tr -d ' ')"
      [[ "$count" =~ ^[0-9]+$ ]] || count=0
      TUI_DOWNLOAD_ZIPS=$((TUI_DOWNLOAD_ZIPS + count))
    fi
  done < <(download_inbox_existing_dirs 2>/dev/null || true)

}

tui_draw_static() {
  local dirty mode manager_inotify now top bottom
  [ "$TUI_ACTIVE" = true ] || return 0
  tui_collect_metrics

  dirty="${#DIRTY_BACKUP_TARGETS[@]}"
  mode="${ACTIVE_MONITOR_MODE:-${AUTO_CODE_MONITOR_MODE:-inotify}}"
  now="$(date '+%H:%M:%S')"
  manager_inotify=0
  [ "$mode" = "inotify" ] && manager_inotify=1

  printf '\0337'
  tui_write_row 1 '44;96;1' "$(tui_border_text '╔' '╗' 'DEV AUTOMATION :: CLIPPER')"
  tui_write_split_row 2 "STATUS: $TUI_STATUS_STATE  $TUI_STATUS_DETAIL" "HORA: $now" '44;93;1'
  tui_write_split_row 3 "MODO: ${mode^^} · manager inotify: $manager_inotify" "PROJETOS: $TUI_PROJECT_COUNT · PENDENTES: $dirty · DL ZIPs: $TUI_DOWNLOAD_ZIPS" '44;97'
  tui_write_split_row 4 "INOTIFY INST: $TUI_INOTIFY_INSTANCES/$TUI_INOTIFY_MAX_INSTANCES" "WATCHES: $TUI_INOTIFY_WATCHES/$TUI_INOTIFY_MAX_WATCHES" '44;96;1'
  tui_write_split_row 5 "DOWNLOADS: $(download_inbox_summary)" "ZIPs CODE: $TUI_ZIP_COUNT · debounce ${BACKUP_EVERY}s" '44;97;1'
  tui_write_row 6 '44;96;1' "$(tui_border_text '╠' '╣' 'ÚLTIMA AÇÃO')"
  tui_write_box_row 7 "$TUI_LAST_ACTION" '44;93;1'
  tui_write_row 8 '44;96;1' "$(tui_border_text '╠' '╣' 'LOG · área rolável')"
  tui_write_row "$TUI_ROWS" '44;96;1' "$(tui_border_text '╚' '╝' 'CTRL+C sair')"
  printf '\0338'
}

tui_relayout() {
  local size rows cols
  [ "$TUI_ACTIVE" = true ] || return 0
  size="$(tui_terminal_size)"
  read -r rows cols <<<"$size"
  if [ "$rows" -lt 16 ] || [ "$cols" -lt 80 ]; then
    return 1
  fi
  TUI_ROWS="$rows"
  TUI_COLS="$cols"
  TUI_LOG_TOP=9

  printf '\033[r\033[2J\033[H\033[44m'
  printf '\033[%s;%sr' "$TUI_LOG_TOP" "$((TUI_ROWS-1))"
  tui_draw_static
  printf '\033[%s;1H\033[44;97m' "$TUI_LOG_TOP"
}

tui_refresh() {
  local size rows cols
  [ "$TUI_ACTIVE" = true ] || return 0
  size="$(tui_terminal_size)"
  read -r rows cols <<<"$size"
  if [ "$rows" != "$TUI_ROWS" ] || [ "$cols" != "$TUI_COLS" ]; then
    tui_relayout || return 0
  else
    tui_draw_static
  fi
}

tui_init() {
  local size rows cols
  tui_supported || return 0
  size="$(tui_terminal_size)"
  read -r rows cols <<<"$size"
  if [ "$rows" -lt 16 ] || [ "$cols" -lt 80 ]; then
    return 0
  fi

  mkdir -p -- "$STATE_DIR"
  : > "$TUI_LOG_FILE"
  TUI_ACTIVE=true
  printf '\033[?1049h\033[?25l'
  tui_relayout || {
    tui_cleanup
    return 0
  }
}

tui_log_line() {
  local context="$1" message="$2" color='44;97'
  local stamp
  [ "$TUI_ACTIVE" = true ] || return 1
  stamp="$(date '+%H:%M:%S')"
  case "$context" in
    error) color='44;91;1' ;;
    backup) color='44;92;1' ;;
    downloads|cycle) color='44;96;1' ;;
    sql) color='44;95;1' ;;
    zone) color='44;93;1' ;;
    wait) color='44;37' ;;
  esac
  printf '[%s] %s\n' "$stamp" "$message" >> "$TUI_LOG_FILE" 2>/dev/null || true
  tui_refresh
  # Timestamp no mesmo tom da linha, porém levemente mais apagado.
  # O texto principal preserva a intensidade semântica do contexto.
  local stamp_color="${color%;1}"
  [ "$stamp_color" = "$color" ] || true
  printf '\033[%s;2m[%s] \033[%sm%s\033[0m\033[44;97m\n' "$stamp_color" "$stamp" "$color" "$message"
  return 0
}

tui_cleanup() {
  [ "$TUI_ACTIVE" = true ] || return 0
  TUI_ACTIVE=false
  printf '\033[r\033[0m\033[?25h\033[?1049l'
}

tui_on_resize() {
  [ "$TUI_ACTIVE" = true ] || return 0
  tui_relayout || true
}

