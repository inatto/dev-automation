#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DIGITAR_DATA_HORA="$SCRIPT_DIR/digitar-data-hora.sh"
GLOBAL_SHORTCUTS_COMMAND="${GLOBAL_SHORTCUTS_COMMAND:-$HOME/.local/bin/Global-Shortcuts}"
DIGITAR_DATA_HORA_KEYBINDING_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/dev-automation-digitar-data-hora/"
YDOTOOLD_SERVICE_NAME="dev-automation-ydotoold.service"
YDOTOOLD_SERVICE_PATH="/etc/systemd/system/$YDOTOOLD_SERVICE_NAME"

log() { printf '[Global-Shortcuts] %s\n' "$*"; }

ensure_ydotoold_boot_service() {
  [[ "$(uname -s 2>/dev/null || true)" == "Linux" ]] || return 0
  [[ -x /usr/bin/ydotoold ]] || {
    log "AVISO: /usr/bin/ydotoold não encontrado; serviço de inicialização não foi configurado."
    return 0
  }
  command -v systemctl >/dev/null 2>&1 || {
    log "AVISO: systemctl não encontrado; ydotoold não pôde ser configurado para iniciar com o Ubuntu."
    return 0
  }

  local uid gid desired current needs_install=0
  uid="$(id -u)"
  gid="$(id -g)"
  desired="$(cat <<EOF_SERVICE
[Unit]
Description=ydotoold for Dev Automation Global Shortcuts
After=systemd-udevd.service
Wants=systemd-udevd.service

[Service]
Type=simple
ExecStartPre=/usr/bin/rm -f /run/ydotool-dm.sock
ExecStart=/usr/bin/ydotoold --socket-path=/run/ydotool-dm.sock --socket-own=${uid}:${gid} --socket-perm=0600
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF_SERVICE
)"

  if [[ -r "$YDOTOOLD_SERVICE_PATH" ]]; then
    current="$(cat "$YDOTOOLD_SERVICE_PATH")"
    [[ "$current" == "$desired" ]] || needs_install=1
  else
    needs_install=1
  fi

  if (( needs_install == 1 )); then
    if ! command -v sudo >/dev/null 2>&1; then
      log "AVISO: sudo não encontrado; não foi possível instalar $YDOTOOLD_SERVICE_NAME."
      return 0
    fi
    printf '%s\n' "$desired" | sudo tee "$YDOTOOLD_SERVICE_PATH" >/dev/null || {
      log "AVISO: não foi possível instalar $YDOTOOLD_SERVICE_NAME."
      return 0
    }
    sudo systemctl daemon-reload >/dev/null || true
  fi

  if ! systemctl is-enabled --quiet "$YDOTOOLD_SERVICE_NAME" 2>/dev/null || ! systemctl is-active --quiet "$YDOTOOLD_SERVICE_NAME" 2>/dev/null; then
    if command -v sudo >/dev/null 2>&1; then
      sudo systemctl enable --now "$YDOTOOLD_SERVICE_NAME" >/dev/null || {
        log "AVISO: não foi possível habilitar/iniciar $YDOTOOLD_SERVICE_NAME."
        return 0
      }
    else
      log "AVISO: $YDOTOOLD_SERVICE_NAME existe, mas não pôde ser habilitado sem sudo."
      return 0
    fi
  fi

  log "ydotoold garantido no boot: /run/ydotool-dm.sock"
}

ensure_gnome_shortcut() {
  command -v gsettings >/dev/null 2>&1 || {
    log "AVISO: gsettings não encontrado; atalhos GNOME não puderam ser conferidos."
    return 0
  }

  if ! gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings >/dev/null 2>&1; then
    log "AVISO: sessão GNOME indisponível; atalhos serão restaurados na próxima inicialização do Dev Automation em sessão gráfica."
    return 0
  fi

  local current updated
  current="$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || printf '@as []')"
  updated="$(python3 - "$current" "$DIGITAR_DATA_HORA_KEYBINDING_PATH" <<'PY_KEYBINDING'
import ast
import sys

raw = sys.argv[1].strip()
path = sys.argv[2]
if raw.startswith('@as '):
    raw = raw[4:].strip()
try:
    values = ast.literal_eval(raw)
except (ValueError, SyntaxError):
    values = []
if not isinstance(values, list):
    values = []
values = [str(value) for value in values]
if path not in values:
    values.append(path)
print(repr(values))
PY_KEYBINDING
)"

  if [[ "$updated" != "$current" && "@as $updated" != "$current" ]]; then
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$updated" >/dev/null
  fi

  gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$DIGITAR_DATA_HORA_KEYBINDING_PATH" name 'Digitar data e hora' >/dev/null
  gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$DIGITAR_DATA_HORA_KEYBINDING_PATH" command "$GLOBAL_SHORTCUTS_COMMAND digitar-data-hora" >/dev/null
  gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$DIGITAR_DATA_HORA_KEYBINDING_PATH" binding '<Primary><Shift><Alt>d' >/dev/null
  log "atalho garantido: Ctrl+Shift+Alt+D -> Global-Shortcuts digitar-data-hora"
}

ensure_all() {
  [[ -x "$DIGITAR_DATA_HORA" ]] || chmod +x "$DIGITAR_DATA_HORA"
  ensure_ydotoold_boot_service
  ensure_gnome_shortcut
}

case "${1:-ensure}" in
  ensure|install|restore)
    ensure_all
    ;;
  digitar-data-hora)
    shift
    exec bash "$DIGITAR_DATA_HORA" "$@"
    ;;
  *)
    printf 'Uso: Global-Shortcuts [ensure|digitar-data-hora]\n' >&2
    exit 2
    ;;
esac
