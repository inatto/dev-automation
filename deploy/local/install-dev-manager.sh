#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
TARGET_DIR="${TARGET_DIR:-$HOME/.local/bin}"
TARGET="$TARGET_DIR/dev-manager"
SOURCE="$PROJECT_ROOT/scripts/dev-manager.sh"
AUTO_SOURCE="$PROJECT_ROOT/scripts/auto-code-manager.sh"

fail() {
  printf '[install-dev-manager] ERRO: %s\n' "$*" >&2
  exit 1
}

[[ -f "$SOURCE" ]] || fail "script não encontrado: $SOURCE"
[[ -f "$AUTO_SOURCE" ]] || fail "script não encontrado: $AUTO_SOURCE"

mkdir -p "$TARGET_DIR"
chmod +x "$SOURCE" "$AUTO_SOURCE"

cat > "$TARGET" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
exec "$SOURCE" "\$@"
EOF_WRAPPER
chmod +x "$TARGET"

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
if ! grep -qxF "$PATH_LINE" "$HOME/.bashrc" 2>/dev/null; then
  printf '\n%s\n' "$PATH_LINE" >> "$HOME/.bashrc"
fi

printf '[install-dev-manager] criado: %s -> %s\n' "$TARGET" "$SOURCE"
printf '[install-dev-manager] execução em primeiro plano; encerre com Ctrl+C.\n'
printf 'No terminal atual, execute: source ~/.bashrc\n'
