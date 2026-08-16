#!/usr/bin/env bash
# Integração GNOME/Wayland do pycharms: instala/habilita a extensão local
# que posiciona as janelas PyCharm no monitor 4K (maior área) e maximiza.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
UUID='pycharms-monitor@dev-automation'
SOURCE_DIR="$PROJECT_ROOT/apps/pycharms-gnome-extension"
TARGET_DIR="$HOME/.local/share/gnome-shell/extensions/$UUID"

log(){ printf '[pycharms/gnome] %s\n' "$*"; }
warn(){ printf '[pycharms/gnome] AVISO: %s\n' "$*" >&2; }

shell_major() {
  local version
  version="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -n1 || true)"
  [[ -n "$version" ]] || version=50
  printf '%s\n' "$version"
}

install_extension() {
  [[ -f "$SOURCE_DIR/extension.js" ]] || { warn "extensão fonte ausente: $SOURCE_DIR"; return 1; }
  command -v gnome-extensions >/dev/null 2>&1 || { warn 'gnome-extensions não encontrado'; return 1; }

  mkdir -p "$TARGET_DIR"
  cp -f "$SOURCE_DIR/extension.js" "$TARGET_DIR/extension.js"

  local major
  major="$(shell_major)"
  cat > "$TARGET_DIR/metadata.json" <<JSON
{
  "uuid": "$UUID",
  "name": "PyCharms Monitor",
  "description": "Reconcilia janelas PyCharm por projeto, workspace e maior monitor no GNOME/Wayland.",
  "shell-version": ["$major"],
  "version": 3
}
JSON

  # Se a extensão já está registrada, force reload para o Shell usar o código
  # recém-copiado nesta mesma sessão. Extensão nova ainda pode exigir login uma vez.
  if gnome-extensions info "$UUID" >/dev/null 2>&1; then
    gnome-extensions disable "$UUID" >/dev/null 2>&1 || true
    gnome-extensions enable "$UUID" >/dev/null 2>&1 || true
  else
    gnome-extensions enable "$UUID" >/dev/null 2>&1 || true
  fi
}

extension_state() {
  if ! command -v gnome-extensions >/dev/null 2>&1; then
    printf 'gnome-extensions ausente\n'
    return 1
  fi
  gnome-extensions info "$UUID" 2>/dev/null || return 1
}

ensure_extension() {
  [[ "${XDG_SESSION_TYPE:-}" == wayland ]] || return 0
  install_extension || return 0
  if gnome-extensions info "$UUID" >/dev/null 2>&1; then
    gnome-extensions enable "$UUID" >/dev/null 2>&1 || true
    log 'extensão GNOME de posicionamento instalada/habilitada.'
  else
    warn 'extensão instalada, mas o GNOME Shell ainda não a registrou; faça logout/login uma vez. PyCharm será aberto mesmo assim.'
  fi
}

show_monitor_diagnose() {
  printf 'SESSION=%s\n' "${XDG_SESSION_TYPE:-desconhecida}"
  printf 'GNOME='; gnome-shell --version 2>/dev/null || printf 'não detectado\n'
  printf '\nMonitores xrandr:\n'
  xrandr --listmonitors 2>/dev/null || true
  printf '\nRegra de posicionamento: maior monitor por área (esperado no seu layout: DP-6 3840x2160 central).\n'
  printf '\nExtensão %s:\n' "$UUID"
  extension_state || printf 'não registrada no Shell atual\n'
}

case "${1:-}" in
  ensure|'') ensure_extension ;;
  diagnose) show_monitor_diagnose ;;
  install) install_extension; gnome-extensions enable "$UUID" >/dev/null 2>&1 || true ;;
  *) printf 'Uso: gnome-wayland.sh [ensure|diagnose|install]\n' >&2; exit 2 ;;
esac
