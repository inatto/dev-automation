#!/usr/bin/env bash
# Backend Ubuntu/Linux do comando `chromes`.
set -euo pipefail
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

show_diagnose() {
  printf '=== CHROME / UBUNTU ===\n'
  for cmd in google-chrome-stable google-chrome chromium chromium-browser; do printf '%-22s ' "$cmd:"; command -v "$cmd" || true; done
  printf '\nPacotes apt/dpkg:\n'; dpkg -l 2>/dev/null | grep -Ei 'google-chrome|chromium' || true
  printf '\nSnap:\n'; command -v snap >/dev/null 2>&1 && snap list 2>/dev/null | grep -Ei 'chrome|chromium' || true
  printf '\nFlatpak:\n'; command -v flatpak >/dev/null 2>&1 && flatpak list --app 2>/dev/null | grep -Ei 'chrome|chromium' || true
  printf '\nSessão: %s / %s\n' "${XDG_CURRENT_DESKTOP:-?}" "${XDG_SESSION_TYPE:-?}"
  printf 'Monitores:\n'; command -v xrandr >/dev/null 2>&1 && xrandr --listmonitors 2>/dev/null || true
  printf '\nDetectado pelo comando:\n'; chrome_mode || printf 'NÃO ENCONTRADO\n'
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
  --diagnose|diagnose) show_diagnose; exit 0 ;;
  --help|-h|help) printf 'Uso: chromes | chromes --diagnose\n'; exit 0 ;;
  "") ;;
  *) fail "opção inválida: $1" ;;
esac

IFS=$'\t' read -r mode chrome < <(chrome_mode) || fail 'Google Chrome/Chromium não encontrado. Rode: chromes --diagnose'
log "Ubuntu backend: $mode -> $chrome"

# Mantém os mesmos perfis usados no Windows. Chrome ignora posicionamento onde o compositor Wayland não permite.
common=(--no-first-run)
log 'Abrindo Chrome Daniel (Default) -> ChatGPT...'
run_chrome "$mode" "$chrome" "${common[@]}" --profile-directory=Default --new-window 'https://chatgpt.com/'
sleep 1
log 'Abrindo Chrome Sindicatto (Profile 2)...'
run_chrome "$mode" "$chrome" "${common[@]}" --profile-directory='Profile 2' --new-window 'chrome://newtab/'

# Equivalente Linux ao Explorer que o backend Windows abre em C:\...\Code.
if command -v nautilus >/dev/null 2>&1 && [[ -d /home/daniel/Code ]]; then
  log 'Abrindo Arquivos em /home/daniel/Code...'
  nohup nautilus --new-window /home/daniel/Code >/dev/null 2>&1 &
fi
log 'Concluído.'
