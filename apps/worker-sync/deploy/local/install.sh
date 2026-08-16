#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
PROJECT_ROOT="$(cd -- "$APP_ROOT/../.." && pwd -P)"
USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
REMOTE_NAME="${WORKER_RCLONE_REMOTE:-danielmaiax}"

log() { printf '[worker-sync][install] %s\n' "$*"; }
fail() { printf '[worker-sync][install] ERRO: %s\n' "$*" >&2; exit 1; }

command -v rclone >/dev/null 2>&1 || fail 'rclone não instalado. Execute: sudo apt install -y rclone'
command -v inotifywait >/dev/null 2>&1 || fail 'inotify-tools não instalado. Execute: sudo apt install -y inotify-tools'

if ! rclone listremotes 2>/dev/null | grep -qx "${REMOTE_NAME}:"; then
  fail "remote rclone '${REMOTE_NAME}:' não encontrado. Configure primeiro com: rclone config"
fi

mkdir -p /home/daniel/worker/to /home/daniel/worker/from "$USER_UNIT_DIR"

log 'parando configuração antiga/avulsa, se existir'
systemctl --user disable --now rclone-worker-to.timer 2>/dev/null || true
systemctl --user disable --now rclone-worker-from.timer 2>/dev/null || true
systemctl --user disable --now rclone-worker-to.service 2>/dev/null || true
systemctl --user stop rclone-worker-from.service 2>/dev/null || true
systemctl --user disable --now dev-automation-worker-to.service 2>/dev/null || true
systemctl --user disable --now dev-automation-worker-from.timer 2>/dev/null || true
systemctl --user stop dev-automation-worker-from.service 2>/dev/null || true

install_unit() {
  local source="$1"
  local target="$2"
  sed "s#@PROJECT_ROOT@#$PROJECT_ROOT#g" "$source" > "$target"
}

install_unit "$APP_ROOT/systemd/user/dev-automation-worker-to.service" \
  "$USER_UNIT_DIR/dev-automation-worker-to.service"
install_unit "$APP_ROOT/systemd/user/dev-automation-worker-from.service" \
  "$USER_UNIT_DIR/dev-automation-worker-from.service"
install_unit "$APP_ROOT/systemd/user/dev-automation-worker-from.timer" \
  "$USER_UNIT_DIR/dev-automation-worker-from.timer"

systemctl --user daemon-reload
systemctl --user enable dev-automation-worker-to.service dev-automation-worker-from.timer >/dev/null

log 'instalado. Fluxo fixo:'
log '  /home/daniel/worker/to -> danielmaiax:worker/to'
log '  danielmaiax:worker/from -> /home/daniel/worker/from'
log 'nenhuma sincronização inversa é configurada.'
