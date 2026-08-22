#!/usr/bin/env bash
# Backend Ubuntu/Linux do comando `chromes`.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
PLACEMENT_LIB="$PROJECT_ROOT/scripts/gnome-window-placement.sh"
CONTEXT_LIB="$PROJECT_ROOT/scripts/workspace-project-context.sh"
[[ -f "$PLACEMENT_LIB" ]] && source "$PLACEMENT_LIB"
[[ -f "$CONTEXT_LIB" ]] && source "$CONTEXT_LIB"
log(){ printf '[chromes] %s\n' "$*"; }
fail(){ printf '[chromes] ERRO: %s\n' "$*" >&2; exit 1; }

chrome_mode() {
  local cmd
  for cmd in google-chrome-stable google-chrome chromium chromium-browser; do
    if command -v "$cmd" >/dev/null 2>&1; then printf 'native\t%s\n' "$(command -v "$cmd")"; return 0; fi
  done
  if command -v flatpak >/dev/null 2>&1 && flatpak info com.google.Chrome >/dev/null 2>&1; then printf 'flatpak\tcom.google.Chrome\n'; return 0; fi
  if command -v snap >/dev/null 2>&1 && snap list chromium >/dev/null 2>&1; then printf 'snap\tchromium\n'; return 0; fi
  return 1
}

chrome_user_data_dir() {
  local mode="$1" target="$2" base
  if [[ -n "${CHROMES_USER_DATA_DIR:-}" ]]; then
    printf '%s\n' "$CHROMES_USER_DATA_DIR"
    return 0
  fi
  case "$mode" in
    flatpak) printf '%s\n' "$HOME/.var/app/com.google.Chrome/config/google-chrome" ;;
    snap) printf '%s\n' "$HOME/snap/chromium/current/.config/chromium" ;;
    native)
      base="$(basename -- "$target")"
      case "$base" in
        google-chrome|google-chrome-stable) printf '%s\n' "$HOME/.config/google-chrome" ;;
        chromium|chromium-browser) printf '%s\n' "$HOME/.config/chromium" ;;
        *) printf '%s\n' "$HOME/.config/google-chrome" ;;
      esac
      ;;
    *) printf '%s\n' "$HOME/.config/google-chrome" ;;
  esac
}

profile_metadata() {
  local user_data_dir="$1" action="${2:-list}" needle="${3:-Sindicatto}"
  command -v python3 >/dev/null 2>&1 || return 2
  python3 - "$user_data_dir" "$action" "$needle" <<'PY'
import json
import os
import sys
import unicodedata
from pathlib import Path

root = Path(sys.argv[1]).expanduser()
action = sys.argv[2]
needle = sys.argv[3]
local_state = root / "Local State"

def norm(value):
    text = unicodedata.normalize("NFKD", str(value or ""))
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    return " ".join(text.casefold().split())

try:
    data = json.loads(local_state.read_text(encoding="utf-8"))
except (OSError, ValueError, TypeError):
    data = {}

profile = data.get("profile") or {}
cache = profile.get("info_cache") or {}
last_used = str(profile.get("last_used") or "")

if action == "list":
    print(f"ROOT\t{root}")
    print(f"LOCAL_STATE\t{'OK' if local_state.is_file() else 'AUSENTE'}\t{local_state}")
    print(f"LAST_USED\t{last_used or '-'}")
    if not cache:
        print("PROFILE\t-\t-\t-\t-\t-")
    else:
        def order(item):
            key, meta = item
            try:
                active = float(meta.get("active_time") or 0)
            except (TypeError, ValueError):
                active = 0
            return (key != last_used, -active, key)
        for key, meta in sorted(cache.items(), key=order):
            name = str(meta.get("name") or "-")
            gaia = str(meta.get("gaia_name") or "-")
            user = str(meta.get("user_name") or "-")
            exists = "SIM" if (root / key).is_dir() else "NAO"
            print(f"PROFILE\t{key}\t{name}\t{gaia}\t{user}\t{exists}")
    raise SystemExit(0)

if action == "resolve":
    wanted = norm(needle)
    best = None
    for key, meta in cache.items():
        values = [
            meta.get("name"),
            meta.get("gaia_name"),
            meta.get("user_name"),
            meta.get("shortcut_name"),
        ]
        normalized = [norm(v) for v in values if v]
        score = 0
        if wanted in normalized:
            score = 100
        elif any(wanted and wanted in value for value in normalized):
            score = 80
        elif wanted and wanted in norm(key):
            score = 60
        if score:
            if (root / key).is_dir():
                score += 10
            if key == last_used:
                score += 1
            candidate = (score, key)
            if best is None or candidate > best:
                best = candidate
    if best:
        print(best[1])
        raise SystemExit(0)
    raise SystemExit(1)

raise SystemExit(2)
PY
}

resolve_daniel_profile() {
  local user_data_dir="$1" resolved
  if [[ -n "${CHROMES_DANIEL_PROFILE:-}" ]]; then
    printf '%s\n' "$CHROMES_DANIEL_PROFILE"
    return 0
  fi
  if resolved="$(profile_metadata "$user_data_dir" resolve danielmaiax 2>/dev/null)" && [[ -n "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi
  printf 'Default\n'
}

resolve_sindicatto_profile() {
  local user_data_dir="$1" resolved
  if [[ -n "${CHROMES_SINDICATTO_PROFILE:-}" ]]; then
    printf '%s\n' "$CHROMES_SINDICATTO_PROFILE"
    return 0
  fi
  if resolved="$(profile_metadata "$user_data_dir" resolve Sindicatto 2>/dev/null)" && [[ -n "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi
  # Compatibilidade com a configuração antiga. O diagnóstico deixa explícito
  # quando esse fallback foi necessário, em vez de fingir que "Profile 2" é universal.
  printf 'Profile 2\n'
}

show_profile_diagnose() {
  local mode="$1" chrome="$2" user_data_dir line kind a b c d e resolved source
  user_data_dir="$(chrome_user_data_dir "$mode" "$chrome")"
  printf '\n=== PERFIS CHROME ===\n'
  printf 'User data dir esperado: %s\n' "$user_data_dir"
  if profile_metadata "$user_data_dir" list >"${TMPDIR:-/tmp}/chromes-profile-diagnose.$$" 2>/dev/null; then
    while IFS=$'\t' read -r kind a b c d e; do
      case "$kind" in
        ROOT) printf 'Raiz efetiva: %s\n' "$a" ;;
        LOCAL_STATE) printf 'Local State: %s (%s)\n' "$a" "$b" ;;
        LAST_USED) printf 'Último perfil usado: %s\n' "$a" ;;
        PROFILE)
          if [[ "$a" == '-' ]]; then
            printf 'Perfis no Local State: nenhum encontrado.\n'
          else
            printf '  %-12s nome=%-18s gaia=%-18s usuario=%-28s pasta=%s\n' "$a" "$b" "$c" "$d" "$e"
          fi
          ;;
      esac
    done <"${TMPDIR:-/tmp}/chromes-profile-diagnose.$$"
  else
    printf 'Não foi possível ler metadados de perfil em %s\n' "$user_data_dir"
  fi
  rm -f -- "${TMPDIR:-/tmp}/chromes-profile-diagnose.$$"

  resolved="$(resolve_sindicatto_profile "$user_data_dir")"
  if [[ -n "${CHROMES_SINDICATTO_PROFILE:-}" ]]; then
    source='override CHROMES_SINDICATTO_PROFILE'
  elif profile_metadata "$user_data_dir" resolve Sindicatto >/dev/null 2>&1; then
    source='detectado pelo nome/metadados'
  else
    source='fallback legado; precisa conferir o diagnóstico'
  fi
  printf 'Sindicatto resolvido: %s (%s)\n' "$resolved" "$source"

  printf '\nProcessos Chrome/Chromium em execução (perfil/user-data-dir):\n'
  ps -eo pid=,args= 2>/dev/null | grep -Ei '[c]hrome|[c]hromium' | grep -E -- '--profile-directory|--user-data-dir' | head -20 || true
}

show_diagnose() {
  local detected mode chrome
  printf '=== CHROME / UBUNTU ===\n'
  for cmd in google-chrome-stable google-chrome chromium chromium-browser; do printf '%-22s ' "$cmd:"; command -v "$cmd" || true; done
  printf '\nPacotes apt/dpkg:\n'; dpkg -l 2>/dev/null | grep -Ei 'google-chrome|chromium' || true
  printf '\nSnap:\n'; command -v snap >/dev/null 2>&1 && snap list 2>/dev/null | grep -Ei 'chrome|chromium' || true
  printf '\nFlatpak:\n'; command -v flatpak >/dev/null 2>&1 && flatpak list --app 2>/dev/null | grep -Ei 'chrome|chromium' || true
  printf '\nSessão: %s / %s\n' "${XDG_CURRENT_DESKTOP:-?}" "${XDG_SESSION_TYPE:-?}"
  printf 'Monitores:\n'; command -v xrandr >/dev/null 2>&1 && xrandr --listmonitors 2>/dev/null || true
  printf '\nDetectado pelo comando:\n'
  if detected="$(chrome_mode)"; then
    printf '%s\n' "$detected"
    IFS=$'\t' read -r mode chrome <<<"$detected"
    show_profile_diagnose "$mode" "$chrome"
  else
    printf 'NÃO ENCONTRADO\n'
  fi
}

run_chrome() {
  local mode="$1" target="$2"; shift 2
  case "$mode" in
    native) nohup "$target" "$@" >/dev/null 2>&1 & ;;
    flatpak) nohup flatpak run "$target" "$@" >/dev/null 2>&1 & ;;
    snap) nohup snap run "$target" "$@" >/dev/null 2>&1 & ;;
  esac
}

case "${1:-}" in
  --diagnose|diagnose|--diagnose-profiles|diagnose-profiles) show_diagnose; exit 0 ;;
  --help|-h|help)
    printf 'Uso: chromes | chromes --diagnose\n'
    printf 'Abre ChatGPT + URL(s) local(is) do projeto do workspace atual; monitor esquerdo e maximizado.\n'
    printf 'Overrides de perfil: CHROMES_USER_DATA_DIR=/caminho CHROMES_DANIEL_PROFILE="Default" CHROMES_SINDICATTO_PROFILE="Profile 1"\n'
    exit 0
    ;;
  "") ;;
  *) fail "opção inválida: $1" ;;
esac

IFS=$'\t' read -r mode chrome < <(chrome_mode) || fail 'Google Chrome/Chromium não encontrado. Rode: chromes --diagnose'
log "Ubuntu backend: $mode -> $chrome"
user_data_dir="$(chrome_user_data_dir "$mode" "$chrome")"
daniel_profile="$(resolve_daniel_profile "$user_data_dir")"
sindicatto_profile="$(resolve_sindicatto_profile "$user_data_dir")"

placement_active=0
target_workspace="${CHROMES_TARGET_WORKSPACE:-}"
if [[ "${XDG_SESSION_TYPE:-}" == wayland ]] && command -v gnome-shell >/dev/null 2>&1; then
  declare -F gnome_placement_prepare >/dev/null 2>&1 || fail "biblioteca GNOME de posicionamento ausente: $PLACEMENT_LIB"
  placement_fields='maximize=1'
  if [[ -n "${CHROMES_TARGET_WORKSPACE:-}" ]]; then
    [[ "$CHROMES_TARGET_WORKSPACE" =~ ^[1-9][0-9]*$ ]] || fail 'CHROMES_TARGET_WORKSPACE deve ser inteiro positivo.'
    placement_fields="workspace=$CHROMES_TARGET_WORKSPACE"$'\t'"$placement_fields"
  fi
  gnome_placement_prepare chromes default "$placement_fields" || fail 'não foi possível preparar o monitor esquerdo no GNOME/Wayland.'
  placement_active=1
  target_workspace="$(gnome_placement_ready_field workspace 2>/dev/null || printf '?')"
  if [[ -n "${CHROMES_TARGET_WORKSPACE:-}" ]]; then
    log "Destino: workspace $target_workspace, monitor mais à esquerda, maximizado."
  else
    log "Destino: workspace atual $target_workspace, monitor mais à esquerda, maximizado."
  fi
elif [[ -n "${CHROMES_TARGET_WORKSPACE:-}" ]]; then
  [[ "$CHROMES_TARGET_WORKSPACE" =~ ^[1-9][0-9]*$ ]] || fail 'CHROMES_TARGET_WORKSPACE deve ser inteiro positivo.'
fi

local_urls=()
project_entry=''
if [[ -n "${CHROMES_LOCAL_URLS:-}" ]]; then
  mapfile -t local_urls < <(printf '%s\n' "$CHROMES_LOCAL_URLS" | sed '/^[[:space:]]*$/d')
elif [[ "$target_workspace" =~ ^[1-9][0-9]*$ ]] && declare -F workspace_context_load_projects >/dev/null 2>&1; then
  if workspace_context_load_projects && workspace_context_load_services; then
    project_entry="$(workspace_context_project_for_workspace "$target_workspace" 2>/dev/null || true)"
    if [[ -n "$project_entry" ]]; then
      project_urls="$(workspace_context_urls_for_project "$project_entry" 2>/dev/null || true)"
      if [[ -n "$project_urls" ]]; then
        mapfile -t local_urls < <(printf '%s\n' "$project_urls" | sed '/^[[:space:]]*$/d')
      fi
    fi
  fi
fi

common=(--no-first-run)
log "Abrindo Chrome Daniel ($daniel_profile) -> ChatGPT..."
run_chrome "$mode" "$chrome" "${common[@]}" --profile-directory="$daniel_profile" --new-window 'https://chatgpt.com/'
expected_browsers=1

skip_second=0
if [[ "${CHROMES_SKIP_SECOND:-}" == 1 ]] || ((${#local_urls[@]} == 0)); then
  skip_second=1
fi

if (( ! skip_second )); then
  sleep 1
  if [[ -n "$project_entry" ]]; then
    log "Projeto: $(basename -- "$project_entry") -> ${local_urls[*]}"
  fi
  log "Abrindo Chrome Sindicatto ($sindicatto_profile) -> ${local_urls[*]}"
  run_chrome "$mode" "$chrome" "${common[@]}" --profile-directory="$sindicatto_profile" --new-window "${local_urls[@]}"
  expected_browsers=2
else
  if [[ -n "$project_entry" ]]; then
    log "Chrome Sindicatto ignorado: $(basename -- "$project_entry") não possui URL local configurada."
  else
    log 'Chrome Sindicatto ignorado: workspace sem URL local configurada.'
  fi
fi

if (( placement_active )); then
  if gnome_placement_wait_min chromes browsers "$expected_browsers" 120; then
    if [[ -n "${CHROMES_TARGET_WORKSPACE:-}" ]]; then
      log "Chrome confirmado no workspace $target_workspace / monitor esquerdo / maximizado."
    else
      log 'Chrome confirmado no workspace atual / monitor esquerdo / maximizado.'
    fi
  else
    fail "o GNOME não confirmou $expected_browsers nova(s) janela(s) Chrome no monitor esquerdo."
  fi
fi
log 'Concluído.'
