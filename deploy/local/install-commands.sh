#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
TARGET_DIR="${TARGET_DIR:-$HOME/.local/bin}"
AUTO_SOURCE="$PROJECT_ROOT/scripts/auto-code-manager.sh"
AUTO_TARGET="$TARGET_DIR/auto-code-manager"
PROJECT_INSTALLER="$PROJECT_ROOT/deploy/local/install-project-commands.sh"
PROJECT_RUNNER="$PROJECT_ROOT/scripts/project-command.sh"
PROJECT_ALL_RUNNER="$PROJECT_ROOT/scripts/project-all-command.sh"
ORACLE_MONITOR_DIR="$PROJECT_ROOT/apps/oracle-monitor"
CHROMES_SOURCE="$PROJECT_ROOT/scripts/chromes.sh"
CHATGPTS_SOURCE="$PROJECT_ROOT/scripts/chatgpts.sh"
PHPSTORMS_SOURCE="$PROJECT_ROOT/scripts/phpstorms.sh"
PYCHARMS_SOURCE="$PROJECT_ROOT/scripts/pycharms.sh"
PHPSTORM_DEV_SOURCE="$PROJECT_ROOT/scripts/phpstorm-dev.sh"
DEV_MANAGER_SOURCE="$PROJECT_ROOT/scripts/dev-manager.sh"
DESKTOPS_SOURCE="$PROJECT_ROOT/scripts/desktops.sh"
LOCAL_NGINX_SOURCE="$PROJECT_ROOT/scripts/local-nginx.sh"
DEV_STATUS_SOURCE="$PROJECT_ROOT/scripts/dev-status.sh"
CLEAR_TERMINAL_SOURCE="$PROJECT_ROOT/scripts/clear-terminal.sh"

log() { printf '[install-commands] %s\n' "$*"; }
fail() { printf '[install-commands] ERRO: %s\n' "$*" >&2; exit 1; }

[[ -f "$AUTO_SOURCE" ]] || fail "script não encontrado: $AUTO_SOURCE"
[[ -f "$PROJECT_INSTALLER" ]] || fail "instalador não encontrado: $PROJECT_INSTALLER"
[[ -f "$PROJECT_RUNNER" ]] || fail "executor de projetos não encontrado: $PROJECT_RUNNER"
[[ -f "$PROJECT_ALL_RUNNER" ]] || fail "executor geral de projetos não encontrado: $PROJECT_ALL_RUNNER"
[[ -d "$ORACLE_MONITOR_DIR" ]] || fail "aplicação não encontrada: $ORACLE_MONITOR_DIR"
[[ -f "$CHROMES_SOURCE" ]] || fail "script não encontrado: $CHROMES_SOURCE"
[[ -f "$CHATGPTS_SOURCE" ]] || fail "script não encontrado: $CHATGPTS_SOURCE"
[[ -f "$PHPSTORMS_SOURCE" ]] || fail "script não encontrado: $PHPSTORMS_SOURCE"
[[ -f "$PYCHARMS_SOURCE" ]] || fail "script não encontrado: $PYCHARMS_SOURCE"
[[ -f "$PHPSTORM_DEV_SOURCE" ]] || fail "script não encontrado: $PHPSTORM_DEV_SOURCE"
[[ -f "$DEV_MANAGER_SOURCE" ]] || fail "script não encontrado: $DEV_MANAGER_SOURCE"
[[ -f "$DESKTOPS_SOURCE" ]] || fail "script não encontrado: $DESKTOPS_SOURCE"
[[ -f "$LOCAL_NGINX_SOURCE" ]] || fail "script não encontrado: $LOCAL_NGINX_SOURCE"
[[ -f "$DEV_STATUS_SOURCE" ]] || fail "script não encontrado: $DEV_STATUS_SOURCE"
[[ -f "$CLEAR_TERMINAL_SOURCE" ]] || fail "script não encontrado: $CLEAR_TERMINAL_SOURCE"

mkdir -p "$TARGET_DIR"
chmod +x "$AUTO_SOURCE" "$PROJECT_INSTALLER" "$PROJECT_RUNNER" "$PROJECT_ALL_RUNNER" "$CHROMES_SOURCE" "$CHATGPTS_SOURCE" "$PHPSTORMS_SOURCE" "$PYCHARMS_SOURCE" "$PHPSTORM_DEV_SOURCE" "$DEV_MANAGER_SOURCE" "$DESKTOPS_SOURCE" "$LOCAL_NGINX_SOURCE" "$DEV_STATUS_SOURCE" "$CLEAR_TERMINAL_SOURCE"

rm -f "$AUTO_TARGET"
cat > "$AUTO_TARGET" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
bash "$CLEAR_TERMINAL_SOURCE"
exec "$AUTO_SOURCE" "\$@"
EOF_WRAPPER
chmod +x "$AUTO_TARGET"
log "criado: auto-code-manager -> $AUTO_SOURCE"

for command_name in chromes chatgpts phpstorms pycharms phpstorm-dev dev-manager desktops local-nginx dev-status; do
  case "$command_name" in
    chromes) source_file="$CHROMES_SOURCE" ;;
    chatgpts) source_file="$CHATGPTS_SOURCE" ;;
    phpstorms) source_file="$PHPSTORMS_SOURCE" ;;
    pycharms) source_file="$PYCHARMS_SOURCE" ;;
    phpstorm-dev) source_file="$PHPSTORM_DEV_SOURCE" ;;
    dev-manager) source_file="$DEV_MANAGER_SOURCE" ;;
    desktops) source_file="$DESKTOPS_SOURCE" ;;
    local-nginx) source_file="$LOCAL_NGINX_SOURCE" ;;
    dev-status) source_file="$DEV_STATUS_SOURCE" ;;
  esac
  target_file="$TARGET_DIR/$command_name"

  rm -f "$target_file"
  cat > "$target_file" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
bash "$CLEAR_TERMINAL_SOURCE"
exec "$source_file" "\$@"
EOF_WRAPPER
  chmod +x "$target_file"
  log "criado: $command_name -> $source_file"
done

ORACLE_MONITOR_TARGET="$TARGET_DIR/oracle-monitor"
rm -f "$ORACLE_MONITOR_TARGET"
cat > "$ORACLE_MONITOR_TARGET" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
exec "$PROJECT_RUNNER" "oracle-monitor" "$ORACLE_MONITOR_DIR" "local" "\$@"
EOF_WRAPPER
chmod +x "$ORACLE_MONITOR_TARGET"
log "criado: oracle-monitor -> $ORACLE_MONITOR_DIR"

TARGET_DIR="$TARGET_DIR" "$PROJECT_INSTALLER"

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
if ! grep -qxF "$PATH_LINE" "$HOME/.bashrc" 2>/dev/null; then
  printf '\n%s\n' "$PATH_LINE" >> "$HOME/.bashrc"
  log 'PATH adicionado ao ~/.bashrc'
fi

export PATH="$TARGET_DIR:$PATH"
hash -r 2>/dev/null || true

printf '\nInstalação concluída com execução direta em primeiro plano.\n'
printf 'No terminal atual, execute:\n  source ~/.bashrc\n\n'
printf 'Testes:\n  command -v auto-code-manager\n  command -v dev-manager\n  command -v chromes\n  command -v chatgpts\n  command -v phpstorms\n  command -v pycharms\n  command -v phpstorm-dev\n  command -v local-nginx\n  command -v dev-status\n  command -v oracle-monitor\n  command -v local-all\n  command -v remote-all\n  phpstorms --list\n  pycharms --list\n  orbital-app help\n  station-app dir\n'
