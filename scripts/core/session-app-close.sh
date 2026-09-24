#!/usr/bin/env bash
# Helper interno para encerrar aplicações gráficas do usuário.
# Fecha somente o processo principal da aplicação com SIGTERM; processos filhos
# são encerrados pela própria aplicação. Para Chrome/Chromium, `chromes-close`
# procura todos os processos principais do usuário, mesmo se um processo antigo
# não tiver herdado WAYLAND_DISPLAY/DISPLAY/XDG_SESSION_ID.
set -euo pipefail

app="${1:-}"
[[ -n "$app" ]] || { printf '[app-close] ERRO: aplicação não informada.\n' >&2; exit 2; }

case "$app" in
  files)
    prefix='files-close'
    description='Files/Nautilus'
    ;;
  chromes)
    prefix='chromes-close'
    description='Google Chrome/Chromium'
    ;;
  *)
    printf '[app-close] ERRO: aplicação inválida: %s\n' "$app" >&2
    exit 2
    ;;
esac

log(){ printf '[%s] %s\n' "$prefix" "$*"; }
warn(){ printf '[%s] AVISO: %s\n' "$prefix" "$*" >&2; }

proc_root="${APP_CLOSE_PROC_ROOT:-/proc}"
current_wayland="${WAYLAND_DISPLAY:-}"
current_display="${DISPLAY:-}"
current_session="${XDG_SESSION_ID:-}"
wait_attempts="${APP_CLOSE_WAIT_ATTEMPTS:-30}"
wait_interval="${APP_CLOSE_WAIT_INTERVAL:-0.10}"

[[ "$wait_attempts" =~ ^[0-9]+$ ]] || wait_attempts=30

belongs_to_current_graphical_session() {
  local pid="$1" env_file="$proc_root/$pid/environ" env_text
  [[ -r "$env_file" ]] || return 1
  env_text="$(tr '\0' '\n' < "$env_file" 2>/dev/null || true)"

  if [[ -n "$current_wayland" ]] && grep -Fxq "WAYLAND_DISPLAY=$current_wayland" <<<"$env_text"; then
    return 0
  fi
  if [[ -n "$current_display" ]] && grep -Fxq "DISPLAY=$current_display" <<<"$env_text"; then
    return 0
  fi
  if [[ -n "$current_session" ]] && grep -Fxq "XDG_SESSION_ID=$current_session" <<<"$env_text"; then
    return 0
  fi

  # Sem identificador gráfico disponível, limita ao usuário atual. É melhor
  # fechar as instâncias desse usuário do que fingir distinguir uma sessão que
  # o próprio ambiente não identificou.
  [[ -z "$current_wayland" && -z "$current_display" && -z "$current_session" ]]
}

is_target_process() {
  local pid="$1" exe_name="$2" arg first_arg='' command_name=''
  case "$app" in
    files)
      [[ "$exe_name" == nautilus ]]
      ;;
    chromes)
      while IFS= read -r arg; do
        [[ -n "$first_arg" ]] || first_arg="$arg"
        [[ "$arg" == --type=* ]] && return 1
      done < <(tr '\0' '\n' < "$proc_root/$pid/cmdline" 2>/dev/null || true)
      command_name="${first_arg##*/}"

      # /proc/<pid>/exe normalmente termina em "chrome", mas snap/wrappers podem
      # expor o nome apenas no argv[0]. Aceitamos ambos e seguimos excluindo
      # renderer/GPU/zygote pelo --type= acima.
      case "$exe_name:$command_name" in
        chrome:*|chrome-beta:*|chrome-unstable:*|google-chrome:*|google-chrome-stable:*|google-chrome-beta:*|google-chrome-unstable:*|chromium:*|chromium-browser:*|\
        *:chrome|*:chrome-beta|*:chrome-unstable|*:google-chrome|*:google-chrome-stable|*:google-chrome-beta|*:google-chrome-unstable|*:chromium|*:chromium-browser)
          return 0
          ;;
        *) return 1 ;;
      esac
      ;;
  esac
}
collect_pids() {
  local proc_dir pid proc_uid exe exe_name
  target_pids=()

  for proc_dir in "$proc_root"/[0-9]*; do
    [[ -d "$proc_dir" ]] || continue
    pid="${proc_dir##*/}"
    [[ "$pid" != "$$" ]] || continue
    [[ -r "$proc_dir/status" ]] || continue

    proc_uid="$(awk '/^Uid:/{print $2; exit}' "$proc_dir/status" 2>/dev/null || true)"
    [[ "$proc_uid" == "$UID" ]] || continue

    exe="$(readlink "$proc_dir/exe" 2>/dev/null || true)"
    [[ -n "$exe" ]] || continue
    exe_name="${exe##*/}"
    is_target_process "$pid" "$exe_name" || continue
    if [[ "$app" != chromes ]]; then
      belongs_to_current_graphical_session "$pid" || continue
    fi
    target_pids+=("$pid")
  done
}

collect_pids
if ((${#target_pids[@]} == 0)); then
  log "nenhum $description aberto para este usuário."
  exit 0
fi

signaled=()
for pid in "${target_pids[@]}"; do
  if kill -TERM "$pid" 2>/dev/null; then
    signaled+=("$pid")
  fi
done

if ((${#signaled[@]} == 0)); then
  warn "os processos encontrados já estavam encerrando ou não aceitaram SIGTERM."
  exit 0
fi

remaining=("${signaled[@]}")
for ((attempt=0; attempt<wait_attempts && ${#remaining[@]}>0; attempt++)); do
  sleep "$wait_interval"
  next_remaining=()
  for pid in "${remaining[@]}"; do
    [[ -d "$proc_root/$pid" ]] && next_remaining+=("$pid")
  done
  remaining=("${next_remaining[@]}")
done

if ((${#remaining[@]} > 0)); then
  warn "SIGTERM enviado para ${#signaled[@]} processo(s); ${#remaining[@]} ainda está(ão) encerrando."
else
  log "fechado(s) ${#signaled[@]} processo(s) principal(is) de $description."
fi
