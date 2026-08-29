#!/usr/bin/env bash
# Biblioteca compartilhada para pedidos explícitos de posicionamento de janelas
# ao controlador GNOME do dev-automation. Não cria UI própria.

GNOME_PLACEMENT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GNOME_PLACEMENT_PROJECT_ROOT="$(cd -- "$GNOME_PLACEMENT_LIB_DIR/.." && pwd -P)"
GNOME_PLACEMENT_STATE_ROOT="${AUTO_CODE_STATE_DIR:-$HOME/.local/state/dev-automation}"
GNOME_PLACEMENT_STATE_DIR="$GNOME_PLACEMENT_STATE_ROOT/desktops"
GNOME_PLACEMENT_TOKEN=''
GNOME_PLACEMENT_READY_LINE=''
GNOME_PLACEMENT_CONTROLLER_VERSION=13

_gnome_placement_log() {
  printf '[window-placement] %s\n' "$*"
}

_gnome_placement_fail() {
  printf '[window-placement] ERRO: %s\n' "$*" >&2
  return 1
}

gnome_placement_supported() {
  [[ "${XDG_SESSION_TYPE:-}" == wayland ]] &&
    command -v gnome-shell >/dev/null 2>&1 &&
    command -v gnome-extensions >/dev/null 2>&1
}

gnome_placement_prepare() {
  local kind="$1" action="${2:-default}" request_fields="${3:-}" request ready result token tmp attempt line
  case "$kind" in
    chromes)
      [[ "$action" == default ]] || { _gnome_placement_fail "ação inválida para chromes: $action"; return 1; }
      ;;
    terminals)
      case "$action" in
        status|open|direct|reconcile|reset|managed-reset) ;;
        *) _gnome_placement_fail "ação inválida para terminals: $action"; return 1 ;;
      esac
      ;;
    *) _gnome_placement_fail "tipo de pedido inválido: $kind"; return 1 ;;
  esac

  gnome_placement_supported || _gnome_placement_fail 'GNOME/Wayland não detectado nesta sessão.' || return 1

  # Fast path idempotente: não reinstala/recarrega extensão a cada comando.
  local controller_ready="$GNOME_PLACEMENT_STATE_DIR/extension.ready" controller_info=""
  controller_info="$(gnome-extensions info workspace-name-osd@dev-automation 2>/dev/null || true)"
  if ! [[ -s "$controller_ready" ]] || \
     ! grep -Fqx "version=$GNOME_PLACEMENT_CONTROLLER_VERSION" "$controller_ready" || \
     ! grep -Fqx 'controller=1' "$controller_ready" || \
     ! grep -Fqx 'window-placement=1' "$controller_ready" || \
     ! grep -qiE '^[[:space:]]*State:[[:space:]]*ACTIVE[[:space:]]*$' <<<"$controller_info"; then
    "$GNOME_PLACEMENT_PROJECT_ROOT/scripts/desktops.sh" --ensure-controller >/dev/null || return 1
  fi

  mkdir -p "$GNOME_PLACEMENT_STATE_DIR"
  request="$GNOME_PLACEMENT_STATE_DIR/$kind.request"
  ready="$GNOME_PLACEMENT_STATE_DIR/$kind.ready"
  result="$GNOME_PLACEMENT_STATE_DIR/$kind.result"
  token="$(date +%s%N)-$$-$RANDOM"
  tmp="$request.tmp.$$"

  rm -f -- "$ready" "$result"
  {
    printf '%s\taction=%s' "$token" "$action"
    [[ -n "$request_fields" ]] && printf '\t%s' "$request_fields"
    printf '\n'
  } > "$tmp"
  mv -f -- "$tmp" "$request"

  for ((attempt=0; attempt<80; attempt++)); do
    if [[ -s "$ready" ]]; then
      line="$(cat "$ready" 2>/dev/null || true)"
      if [[ "${line%%$'\t'*}" == "$token" ]]; then
        GNOME_PLACEMENT_TOKEN="$token"
        GNOME_PLACEMENT_READY_LINE="$line"
        export GNOME_PLACEMENT_TOKEN GNOME_PLACEMENT_READY_LINE
        return 0
      fi
    fi
    sleep 0.1
  done

  _gnome_placement_fail "controlador GNOME não confirmou o pedido '$kind'."
}

gnome_placement_ready_field() {
  local key="$1" field
  while IFS=$'\t' read -ra fields; do
    for field in "${fields[@]}"; do
      if [[ "$field" == "$key="* ]]; then
        printf '%s\n' "${field#*=}"
        return 0
      fi
    done
  done <<<"$GNOME_PLACEMENT_READY_LINE"
  return 1
}

gnome_placement_result_field() {
  local kind="$1" key="$2" result line field
  result="$GNOME_PLACEMENT_STATE_DIR/$kind.result"
  [[ -n "$GNOME_PLACEMENT_TOKEN" && -s "$result" ]] || return 1
  line="$(cat "$result" 2>/dev/null || true)"
  [[ "${line%%$'\t'*}" == "$GNOME_PLACEMENT_TOKEN" ]] || return 1
  IFS=$'\t' read -ra fields <<<"$line"
  for field in "${fields[@]}"; do
    if [[ "$field" == "$key="* ]]; then
      printf '%s\n' "${field#*=}"
      return 0
    fi
  done
  return 1
}

gnome_placement_wait_min() {
  local kind="$1" key="$2" minimum="$3" timeout_tenths="${4:-100}"
  local result="$GNOME_PLACEMENT_STATE_DIR/$kind.result" attempt line value field
  [[ -n "$GNOME_PLACEMENT_TOKEN" ]] || return 1

  for ((attempt=0; attempt<timeout_tenths; attempt++)); do
    if [[ -s "$result" ]]; then
      line="$(cat "$result" 2>/dev/null || true)"
      if [[ "${line%%$'\t'*}" == "$GNOME_PLACEMENT_TOKEN" ]]; then
        value=''
        IFS=$'\t' read -ra fields <<<"$line"
        for field in "${fields[@]}"; do
          if [[ "$field" == "$key="* ]]; then
            value="${field#*=}"
            break
          fi
        done
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= minimum )); then
          return 0
        fi
      fi
    fi
    sleep 0.1
  done
  return 1
}

gnome_placement_wait_complete() {
  local kind="$1" timeout_tenths="${2:-200}"
  local result="$GNOME_PLACEMENT_STATE_DIR/$kind.result" attempt line field complete placed expected
  [[ -n "$GNOME_PLACEMENT_TOKEN" ]] || return 1

  for ((attempt=0; attempt<timeout_tenths; attempt++)); do
    if [[ -s "$result" ]]; then
      line="$(cat "$result" 2>/dev/null || true)"
      if [[ "${line%%$'\t'*}" == "$GNOME_PLACEMENT_TOKEN" ]]; then
        complete='0'; placed='0'; expected='0'
        IFS=$'\t' read -ra fields <<<"$line"
        for field in "${fields[@]}"; do
          case "$field" in
            complete=*) complete="${field#*=}" ;;
            placed=*) placed="${field#*=}" ;;
            expected=*) expected="${field#*=}" ;;
          esac
        done
        if [[ "$complete" == 1 && "$placed" =~ ^[0-9]+$ && "$expected" =~ ^[0-9]+$ && "$placed" -eq "$expected" ]]; then
          return 0
        fi
      fi
    fi
    sleep 0.1
  done
  return 1
}
