#!/usr/bin/env bash
# Garante, de forma idempotente, que os workers definidos pelo dev-automation
# estejam instalados, habilitados e ativos. Não reinicia serviços já saudáveis.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
PROJECT_ROOT="$(cd -- "$APP_ROOT/../.." && pwd -P)"
USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dev-automation/worker-sync"
FINGERPRINT_FILE="$STATE_DIR/source.sha256"

worker_source_fingerprint() {
  find "$APP_ROOT/scripts" "$APP_ROOT/systemd/user" -type f -print0 2>/dev/null | \
    sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | awk '{print $1}'
}

log() { printf '[worker-sync][ensure] %s\n' "$*"; }
warn() { printf '[worker-sync][ensure] AVISO: %s\n' "$*" >&2; }

if ! command -v systemctl >/dev/null 2>&1; then
  warn 'systemctl não encontrado.'
  exit 1
fi

mkdir -p "$USER_UNIT_DIR" /home/daniel/worker/to /home/daniel/worker/from/backup /home/daniel/worker/from/.incoming

render_matches() {
  local source="$1" target="$2" tmp
  [ -f "$target" ] || return 1
  tmp="$(mktemp)" || return 1
  sed "s#@PROJECT_ROOT@#$PROJECT_ROOT#g" "$source" > "$tmp"
  if cmp -s "$tmp" "$target"; then
    rm -f -- "$tmp"
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

needs_install=false
current_fingerprint="$(worker_source_fingerprint 2>/dev/null || true)"
installed_fingerprint="$(cat "$FINGERPRINT_FILE" 2>/dev/null || true)"
if [ -z "$current_fingerprint" ] || [ "$current_fingerprint" != "$installed_fingerprint" ]; then
  log 'scripts/units do worker-sync mudaram; atualização necessária.'
  needs_install=true
fi
render_matches "$APP_ROOT/systemd/user/dev-automation-worker-to.service" \
  "$USER_UNIT_DIR/dev-automation-worker-to.service" || needs_install=true
render_matches "$APP_ROOT/systemd/user/dev-automation-worker-from.service" \
  "$USER_UNIT_DIR/dev-automation-worker-from.service" || needs_install=true
render_matches "$APP_ROOT/systemd/user/dev-automation-worker-from.timer" \
  "$USER_UNIT_DIR/dev-automation-worker-from.timer" || needs_install=true
render_matches "$APP_ROOT/systemd/user/dev-automation-worker-from-delete.service" \
  "$USER_UNIT_DIR/dev-automation-worker-from-delete.service" || needs_install=true

if [ "$needs_install" = true ]; then
  log 'units ausentes/desatualizados; instalando a versão do dev-automation...'
  "$SCRIPT_DIR/install.sh" || exit $?
else
  log 'units já correspondem ao dev-automation.'
fi

# enable/start são idempotentes: se já estiver habilitado/ativo, nada é reiniciado.
systemctl --user daemon-reload >/dev/null 2>&1 || true
systemctl --user enable dev-automation-worker-to.service dev-automation-worker-from.timer dev-automation-worker-from-delete.service >/dev/null 2>&1 || true

if ! systemctl --user is-active --quiet dev-automation-worker-to.service; then
  log 'iniciando worker TO...'
  systemctl --user start dev-automation-worker-to.service || exit $?
fi

# O backup watcher sobe primeiro para limpar qualquer item já processado antes
# do downloader verificar novamente a raiz remota.
if ! systemctl --user is-active --quiet dev-automation-worker-from-delete.service; then
  log 'iniciando worker FROM backup-sync/recovery...'
  systemctl --user start dev-automation-worker-from-delete.service || exit $?
fi

if ! systemctl --user is-active --quiet dev-automation-worker-from.timer; then
  log 'iniciando worker FROM download...'
  systemctl --user start dev-automation-worker-from.timer || exit $?
fi

if systemctl --user is-active --quiet dev-automation-worker-to.service && \
   systemctl --user is-active --quiet dev-automation-worker-from.timer && \
   systemctl --user is-active --quiet dev-automation-worker-from-delete.service; then
  log 'OK: TO ativo · FROM ativo'
  exit 0
fi

warn 'um ou mais workers não ficaram ativos.'
exit 1
