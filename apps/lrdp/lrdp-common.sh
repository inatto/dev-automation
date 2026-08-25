#!/usr/bin/env bash
# Funções comuns de configuração para lrdp1/lrdp2/... e para a TUI LRDP.

LRDP_STATE_ROOT="${LRDP_STATE_ROOT:-${XDG_CONFIG_HOME:-$HOME/.config}/dev-automation/lrdp}"
LRDP_STATE_FILE="$LRDP_STATE_ROOT/${LRDP_NAME}.conf"
LRDP_LABEL="${LRDP_LABEL:-${LRDP_NAME^^}}"
LRDP_PORT="${LRDP_PORT:-3389}"

saved_login_index=1
saved_audio_mode=server
saved_microphone=no
saved_primary_monitor=""

load_lrdp_state() {
  local key value
  [[ -f "$LRDP_STATE_FILE" ]] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      login_index) [[ "$value" =~ ^[0-9]+$ ]] && saved_login_index="$value" ;;
      audio_mode) [[ "$value" =~ ^(redirect|server|none)$ ]] && saved_audio_mode="$value" ;;
      microphone) [[ "$value" =~ ^(yes|no)$ ]] && saved_microphone="$value" ;;
      primary_monitor) [[ -z "$value" || "$value" =~ ^[0-9]+$ ]] && saved_primary_monitor="$value" ;;
    esac
  done < "$LRDP_STATE_FILE"
}

save_lrdp_state() {
  mkdir -p "$LRDP_STATE_ROOT"
  umask 077
  cat > "$LRDP_STATE_FILE" <<STATE
login_index=$selected_login_index
audio_mode=$selected_audio_mode
microphone=$selected_microphone
primary_monitor=$selected_primary_monitor
STATE
}

# Saída deliberadamente sem senha. Consumida pela TUI para descobrir RDPs
# dinamicamente sem duplicar host, usuários ou labels em outro arquivo.
print_lrdp_metadata() {
  local index profile label username password
  printf 'name\t%s\n' "$LRDP_NAME"
  printf 'label\t%s\n' "$LRDP_LABEL"
  printf 'target\t%s\n' "$LRDP_TARGET"
  printf 'port\t%s\n' "$LRDP_PORT"
  for index in "${!LOGIN_PROFILES[@]}"; do
    profile="${LOGIN_PROFILES[$index]}"
    IFS='|' read -r label username password <<< "$profile"
    printf 'login\t%s\t%s\t%s\n' "$label" "$username" "$([[ -n "$password" ]] && printf yes || printf no)"
  done
}

monitor_list_output=""
monitor_ids=()
monitor_local_primary=""
declare -A monitor_x=()

load_monitor_layout() {
  local line id x
  monitor_list_output="$(xfreerdp3 /list:monitor 2>&1 || true)"
  monitor_ids=()
  monitor_local_primary=""
  monitor_x=()
  while IFS= read -r line; do
    if [[ "$line" =~ \[([0-9]+)\] ]]; then
      id="${BASH_REMATCH[1]}"
      [[ " ${monitor_ids[*]} " == *" $id "* ]] || monitor_ids+=("$id")
      if [[ "$line" =~ ^[[:space:]]*\* ]]; then
        monitor_local_primary="$id"
      fi
      if [[ "$line" =~ ([+-][0-9]+)([+-][0-9]+)[[:space:]]*$ ]]; then
        x="${BASH_REMATCH[1]}"
        monitor_x["$id"]="$x"
      fi
    fi
  done <<< "$monitor_list_output"
}

show_monitor_layout() {
  printf '\nMonitores detectados pelo FreeRDP:\n' >&2
  if [[ -n "$monitor_list_output" ]]; then
    printf '%s\n' "$monitor_list_output" >&2
  else
    printf '  Não foi possível obter /list:monitor.\n' >&2
  fi
  if [[ ${#monitor_ids[@]} -gt 0 ]]; then
    printf 'IDs detectados: %s\n' "${monitor_ids[*]}" >&2
    local ordered="" pair id
    while IFS= read -r pair; do
      id="${pair#* }"
      [[ -n "$id" ]] && ordered+=" [$id]"
    done < <(for id in "${monitor_ids[@]}"; do
      [[ -n "${monitor_x[$id]:-}" ]] && printf '%s %s\n' "${monitor_x[$id]}" "$id"
    done | sort -n -k1,1)
    if [[ -n "$ordered" ]]; then
      printf 'Esquerda -> direita:%s\n' "$ordered" >&2
    fi
  fi
  printf '\n' >&2
}

monitor_exists() {
  local wanted="$1" id
  for id in "${monitor_ids[@]}"; do
    [[ "$id" == "$wanted" ]] && return 0
  done
  return 1
}

choose_primary_monitor() {
  local choice default
  if [[ ${#monitor_ids[@]} -eq 0 ]]; then
    selected_primary_monitor=""
    return 0
  fi

  default="${saved_primary_monitor:-${monitor_local_primary:-${monitor_ids[0]}}}"
  monitor_exists "$default" || default="${monitor_ids[0]}"

  if [[ ! -t 0 ]]; then
    selected_primary_monitor="$default"
    return 0
  fi

  read -r -p "Monitor principal [${default}]: " choice
  choice="${choice:-$default}"
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || ! monitor_exists "$choice"; then
    printf 'Monitor inválido: %s. IDs válidos: %s\n' "$choice" "${monitor_ids[*]}" >&2
    return 2
  fi
  selected_primary_monitor="$choice"
}

build_monitor_order() {
  local id primary="$1"
  [[ -n "$primary" ]] || return 0
  printf '%s' "$primary"
  for id in "${monitor_ids[@]}"; do
    [[ "$id" == "$primary" ]] && continue
    printf ',%s' "$id"
  done
}

print_saved_summary() {
  local login_label="?" login_user="?" p
  if (( saved_login_index >= 1 && saved_login_index <= ${#LOGIN_PROFILES[@]} )); then
    p="${LOGIN_PROFILES[$((saved_login_index - 1))]}"
    IFS='|' read -r login_label login_user _ <<< "$p"
  fi
  printf 'Última configuração de %s:\n' "$LRDP_NAME" >&2
  printf '  Login: %s (%s)\n' "$login_label" "$login_user" >&2
  printf '  Áudio: %s\n' "$saved_audio_mode" >&2
  printf '  Microfone: %s\n' "$saved_microphone" >&2
  printf '  Principal: %s\n' "${saved_primary_monitor:-automático}" >&2
}

use_saved_configuration() {
  local answer
  [[ -f "$LRDP_STATE_FILE" && -t 0 ]] || return 1
  print_saved_summary
  read -r -p 'Usar essa configuração? [S/n]: ' answer
  case "${answer:-S}" in
    [sS]) return 0 ;;
    [nN]) return 1 ;;
    *) printf 'Resposta inválida: %s (use S ou N)\n' "$answer" >&2; return 2 ;;
  esac
}

choose_login_index() {
  local index choice profile label username password default
  if (( ${#LOGIN_PROFILES[@]} == 0 )); then
    printf 'Nenhum login cadastrado em LOGIN_PROFILES.\n' >&2
    return 2
  fi

  default="$saved_login_index"
  (( default >= 1 && default <= ${#LOGIN_PROFILES[@]} )) || default=1

  if (( ${#LOGIN_PROFILES[@]} == 1 )) || [[ ! -t 0 ]]; then
    selected_login_index="$default"
    return 0
  fi

  printf 'Login RDP:\n' >&2
  for index in "${!LOGIN_PROFILES[@]}"; do
    IFS='|' read -r label username password <<<"${LOGIN_PROFILES[$index]}"
    printf '  %d) %s (%s)%s\n' "$((index + 1))" "$label" "$username" "$([[ $((index + 1)) -eq $default ]] && printf ' [último]')" >&2
  done
  read -r -p "Escolha [$default]: " choice
  choice="${choice:-$default}"
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#LOGIN_PROFILES[@]} )); then
    printf 'Login inválido: %s\n' "$choice" >&2
    return 2
  fi
  selected_login_index="$choice"
}

choose_audio_mode() {
  local choice default_num
  case "$saved_audio_mode" in
    redirect) default_num=1 ;;
    server) default_num=2 ;;
    none) default_num=3 ;;
    *) default_num=2 ;;
  esac

  if [[ ! -t 0 ]]; then
    selected_audio_mode="$saved_audio_mode"
    return 0
  fi

  printf 'Áudio RDP:\n' >&2
  printf '  1) Tocar neste computador\n' >&2
  printf '  2) Tocar no computador remoto (Bluetooth remoto)\n' >&2
  printf '  3) Sem áudio\n' >&2
  read -r -p "Escolha [$default_num]: " choice
  choice="${choice:-$default_num}"
  case "$choice" in
    1) selected_audio_mode=redirect ;;
    2) selected_audio_mode=server ;;
    3) selected_audio_mode=none ;;
    *) printf 'Opção inválida: %s\n' "$choice" >&2; return 2 ;;
  esac
}

choose_microphone_mode() {
  local answer default_label
  default_label="$([[ "$saved_microphone" == yes ]] && printf 'S' || printf 'n')"
  if [[ ! -t 0 ]]; then
    selected_microphone="$saved_microphone"
    return 0
  fi
  read -r -p "Repassar microfone? [${default_label}]: " answer
  if [[ -z "$answer" ]]; then
    selected_microphone="$saved_microphone"
    return 0
  fi
  case "$answer" in
    [sS]) selected_microphone=yes ;;
    [nN]) selected_microphone=no ;;
    *) printf 'Resposta inválida: %s (use S ou N)\n' "$answer" >&2; return 2 ;;
  esac
}

resolve_login_credentials() {
  local profile label
  profile="${LOGIN_PROFILES[$((selected_login_index - 1))]}"
  IFS='|' read -r label rdp_user rdp_password <<< "$profile"
  [[ -n "$rdp_user" ]] || { printf 'Perfil de login inválido: usuário vazio.\n' >&2; return 2; }
}

apply_saved_configuration() {
  selected_login_index="$saved_login_index"
  (( selected_login_index >= 1 && selected_login_index <= ${#LOGIN_PROFILES[@]} )) || selected_login_index=1
  selected_audio_mode="$saved_audio_mode"
  selected_microphone="$saved_microphone"
  selected_primary_monitor="$saved_primary_monitor"
  if [[ -z "$selected_primary_monitor" && ${#monitor_ids[@]} -gt 0 ]]; then
    selected_primary_monitor="${monitor_local_primary:-${monitor_ids[0]}}"
  elif [[ -n "$selected_primary_monitor" ]] && ! monitor_exists "$selected_primary_monitor"; then
    selected_primary_monitor="${monitor_local_primary:-${monitor_ids[0]:-}}"
  fi
}

configure_lrdp() {
  load_lrdp_state
  load_monitor_layout

  # A TUI usa este modo: conecta imediatamente com o estado salvo e nunca
  # imprime/pede configuração no terminal que está desenhando a interface.
  if [[ "${LRDP_USE_SAVED:-0}" == 1 ]]; then
    apply_saved_configuration
    resolve_login_credentials
    return 0
  fi

  show_monitor_layout
  if use_saved_configuration; then
    apply_saved_configuration
  else
    choose_login_index
    choose_audio_mode
    choose_microphone_mode
    choose_primary_monitor
    save_lrdp_state
  fi

  resolve_login_credentials
}
