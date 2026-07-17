#!/usr/bin/env bash
# cd /home/daniel/Code/sind-infra/deploy

set -euo pipefail

# INSTALAÇÃO INICIAL — execute uma única vez em um WSL novo:
#
#   cd /home/daniel/Code/sind-infra
#   chmod +x deploy/install-dev-manager.sh deploy/dev-manager.sh
#   ./deploy/install-dev-manager.sh
#
# Depois, em qualquer pasta, use:
#
#   dev-manager start
#   dev-manager status
#   dev-manager attach
#   dev-manager restart
#   dev-manager stop

PROJECT_ROOT="/home/daniel/Code/sind-infra"
TARGET_DIR="$HOME/.local/bin"
TARGET="$TARGET_DIR/dev-manager"
SOURCE="$PROJECT_ROOT/deploy/dev-manager.sh"

if [[ ! -f "$SOURCE" ]]; then
  echo "Erro: script não encontrado em $SOURCE" >&2
  exit 1
fi

echo "Instalando dependências..."
sudo apt update
sudo apt install -y tmux

mkdir -p "$TARGET_DIR"

cat > "$TARGET" <<EOF_WRAPPER
#!/usr/bin/env bash
exec "$SOURCE" "\$@"
EOF_WRAPPER

chmod +x "$TARGET" "$SOURCE"

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
if ! grep -qxF "$PATH_LINE" "$HOME/.bashrc"; then
  printf '\n%s\n' "$PATH_LINE" >> "$HOME/.bashrc"
fi

export PATH="$HOME/.local/bin:$PATH"
hash -r

echo
echo "Instalação concluída."
echo "Comando global: $TARGET"
echo
echo "Teste agora com:"
echo "  dev-manager status"
echo "  dev-manager start"
echo
echo "Em terminais já abertos, se o comando ainda não for encontrado, execute:"
echo "  source ~/.bashrc"
