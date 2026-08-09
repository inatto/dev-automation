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
ORACLE_MONITOR_DIR="$PROJECT_ROOT/apps/oracle-monitor"
CHROMES_SOURCE="$PROJECT_ROOT/scripts/chromes.sh"
PHPSTORMS_SOURCE="$PROJECT_ROOT/scripts/phpstorms.sh"
PHPSTORM_DEV_SOURCE="$PROJECT_ROOT/scripts/phpstorm-dev.sh"
DEV_MANAGER_SOURCE="$PROJECT_ROOT/scripts/dev-manager.sh"
DESKTOPS_SOURCE="$PROJECT_ROOT/scripts/desktops.sh"

log() { printf '[install-commands] %s\n' "$*"; }
fail() { printf '[install-commands] ERRO: %s\n' "$*" >&2; exit 1; }

[[ -f "$AUTO_SOURCE" ]] || fail "script não encontrado: $AUTO_SOURCE"
[[ -f "$PROJECT_INSTALLER" ]] || fail "instalador não encontrado: $PROJECT_INSTALLER"
[[ -f "$PROJECT_RUNNER" ]] || fail "executor de projetos não encontrado: $PROJECT_RUNNER"
[[ -d "$ORACLE_MONITOR_DIR" ]] || fail "aplicação não encontrada: $ORACLE_MONITOR_DIR"
[[ -f "$CHROMES_SOURCE" ]] || fail "script não encontrado: $CHROMES_SOURCE"
[[ -f "$PHPSTORMS_SOURCE" ]] || fail "script não encontrado: $PHPSTORMS_SOURCE"
[[ -f "$PHPSTORM_DEV_SOURCE" ]] || fail "script não encontrado: $PHPSTORM_DEV_SOURCE"
[[ -f "$DEV_MANAGER_SOURCE" ]] || fail "script não encontrado: $DEV_MANAGER_SOURCE"
[[ -f "$DESKTOPS_SOURCE" ]] || fail "script não encontrado: $DESKTOPS_SOURCE"

mkdir -p "$TARGET_DIR"
chmod +x "$AUTO_SOURCE" "$PROJECT_INSTALLER" "$PROJECT_RUNNER" "$CHROMES_SOURCE" "$PHPSTORMS_SOURCE" "$PHPSTORM_DEV_SOURCE" "$DEV_MANAGER_SOURCE" "$DESKTOPS_SOURCE"

rm -f "$AUTO_TARGET"
cat > "$AUTO_TARGET" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
exec "$AUTO_SOURCE" "\$@"
EOF_WRAPPER
chmod +x "$AUTO_TARGET"
log "criado: auto-code-manager -> $AUTO_SOURCE"

for command_name in chromes phpstorms phpstorm-dev dev-manager desktops; do
  case "$command_name" in
    chromes) source_file="$CHROMES_SOURCE" ;;
    phpstorms) source_file="$PHPSTORMS_SOURCE" ;;
    phpstorm-dev) source_file="$PHPSTORM_DEV_SOURCE" ;;
    dev-manager) source_file="$DEV_MANAGER_SOURCE" ;;
    desktops) source_file="$DESKTOPS_SOURCE" ;;
  esac
  target_file="$TARGET_DIR/$command_name"

  rm -f "$target_file"
  cat > "$target_file" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
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
printf 'Testes:\n  command -v auto-code-manager\n  command -v dev-manager\n  command -v chromes\n  command -v phpstorms\n  command -v phpstorm-dev\n  command -v oracle-monitor\n  phpstorms --list\n  orbital-app help\n  station-app dir\n'
