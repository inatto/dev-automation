#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
TARGET_DIR="${TARGET_DIR:-$HOME/.local/bin}"
AUTO_SOURCE="$PROJECT_ROOT/scripts/auto-code-manager.sh"
AUTO_TARGET="$TARGET_DIR/auto-code-manager"
PROJECT_INSTALLER="$PROJECT_ROOT/deploy/local/install-project-commands.sh"
CHROMES_SOURCE="$PROJECT_ROOT/scripts/chromes.sh"
PHPSTORMS_SOURCE="$PROJECT_ROOT/scripts/phpstorms.sh"
PHPSTORM_DEV_SOURCE="$PROJECT_ROOT/scripts/phpstorm-dev.sh"

log() { printf '[install-commands] %s\n' "$*"; }
fail() { printf '[install-commands] ERRO: %s\n' "$*" >&2; exit 1; }

[[ -f "$AUTO_SOURCE" ]] || fail "script não encontrado: $AUTO_SOURCE"
[[ -f "$PROJECT_INSTALLER" ]] || fail "instalador não encontrado: $PROJECT_INSTALLER"
[[ -f "$CHROMES_SOURCE" ]] || fail "script não encontrado: $CHROMES_SOURCE"
[[ -f "$PHPSTORMS_SOURCE" ]] || fail "script não encontrado: $PHPSTORMS_SOURCE"
[[ -f "$PHPSTORM_DEV_SOURCE" ]] || fail "script não encontrado: $PHPSTORM_DEV_SOURCE"

mkdir -p "$TARGET_DIR"
chmod +x "$AUTO_SOURCE" "$PROJECT_INSTALLER" "$PROJECT_ROOT/scripts/project-command.sh" "$CHROMES_SOURCE" "$PHPSTORMS_SOURCE" "$PHPSTORM_DEV_SOURCE"

rm -f "$AUTO_TARGET"
cat > "$AUTO_TARGET" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
exec "$AUTO_SOURCE" "\$@"
EOF_WRAPPER
chmod +x "$AUTO_TARGET"
log "criado: auto-code-manager -> $AUTO_SOURCE"

for command_name in chromes phpstorms phpstorm-dev; do
  case "$command_name" in
    chromes) source_file="$CHROMES_SOURCE" ;;
    phpstorms) source_file="$PHPSTORMS_SOURCE" ;;
    phpstorm-dev) source_file="$PHPSTORM_DEV_SOURCE" ;;
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

TARGET_DIR="$TARGET_DIR" "$PROJECT_INSTALLER"

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
if ! grep -qxF "$PATH_LINE" "$HOME/.bashrc" 2>/dev/null; then
  printf '\n%s\n' "$PATH_LINE" >> "$HOME/.bashrc"
  log 'PATH adicionado ao ~/.bashrc'
fi

export PATH="$TARGET_DIR:$PATH"
hash -r 2>/dev/null || true

printf '\nInstalação concluída sem tmux.\n'
printf 'No terminal atual, execute:\n  source ~/.bashrc\n\n'
printf 'Testes:\n  command -v auto-code-manager\n  command -v chromes\n  command -v phpstorms\n  command -v phpstorm-dev\n  orbital-app help\n  station-app dir\n'
