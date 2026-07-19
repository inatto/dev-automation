#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation

set -euo pipefail

# COMO INSTALAR OU ATUALIZAR OS COMANDOS GLOBAIS
# ================================================================
# 1. Entre na pasta deste projeto:
#
#      cd /home/daniel/Code/bots/dev-automation
#
# 2. Garanta permissão de execução:
#
#      chmod +x install-project-commands.sh project-command.sh
#
# 3. Gere ou atualize os atalhos globais:
#
#      ./install-project-commands.sh
#
# 4. Recarregue o terminal atual:
#
#      source ~/.bashrc
#
# 5. Teste de qualquer pasta:
#
#      orbital-app help
#      station-app dir
#      inst-app scripts
#
# USO DOS COMANDOS GERADOS
# ================================================================
#   orbital-app              -> deploy/local/start.sh
#   orbital-app start        -> deploy/local/start.sh
#   orbital-app setup        -> deploy/local/setup.sh
#   orbital-app run          -> setup.sh + start.sh
#   orbital-app test         -> deploy/local/test.sh
#   orbital-app start-api    -> deploy/local/start-api.sh
#   orbital-app setup-web    -> deploy/local/setup-web.sh
#
# O instalador lê auto-code-manager.projects. Ele cria um comando apenas
# para entradas que possuam deploy/local/start.sh ou setup.sh. Portanto,
# pastas agrupadoras como "infra" são ignoradas com segurança.
#
# Sempre que adicionar, remover ou renomear um projeto em
# auto-code-manager.projects, execute este instalador novamente.
# ================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECTS_FILE="${PROJECTS_FILE:-$SCRIPT_DIR/auto-code-manager.projects}"
COMMAND_RUNNER="${COMMAND_RUNNER:-$SCRIPT_DIR/project-command.sh}"
CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
TARGET_DIR="${TARGET_DIR:-$HOME/.local/bin}"
MANIFEST_FILE="$TARGET_DIR/.dev-automation-project-commands"

log() {
  printf '[project-commands] %s\n' "$*"
}

fail() {
  printf '[project-commands] ERRO: %s\n' "$*" >&2
  exit 1
}

[[ -f "$PROJECTS_FILE" ]] || fail "arquivo de projetos não encontrado: $PROJECTS_FILE"
[[ -f "$COMMAND_RUNNER" ]] || fail "executor não encontrado: $COMMAND_RUNNER"

chmod +x "$COMMAND_RUNNER"
mkdir -p "$TARGET_DIR"

# Remove somente atalhos anteriormente gerados por este instalador.
if [[ -f "$MANIFEST_FILE" ]]; then
  while IFS= read -r old_command; do
    [[ -n "$old_command" ]] || continue
    old_path="$TARGET_DIR/$old_command"
    if [[ -f "$old_path" ]] && grep -q '^# generated-by: dev-automation-project-commands$' "$old_path"; then
      rm -f "$old_path"
      log "atalho antigo removido: $old_command"
    fi
  done < "$MANIFEST_FILE"
fi

new_manifest="$(mktemp)"
trap 'rm -f "$new_manifest"' EXIT
created=0
skipped=0

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line="${raw_line%%#*}"
  line="$(printf '%s' "$line" | xargs)"
  [[ -n "$line" ]] || continue

  project_dir="$CODE_ROOT/$line"
  command_name="$(basename "$line")"

  if [[ ! -d "$project_dir" ]]; then
    log "ignorado; pasta não existe: $project_dir"
    ((skipped += 1))
    continue
  fi

  if [[ ! -f "$project_dir/deploy/local/start.sh" && ! -f "$project_dir/deploy/local/setup.sh" ]]; then
    log "ignorado; sem deploy local de aplicação: $line"
    ((skipped += 1))
    continue
  fi

  target="$TARGET_DIR/$command_name"
  cat > "$target" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-project-commands
exec "$COMMAND_RUNNER" "$command_name" "$project_dir" "\$@"
EOF_WRAPPER
  chmod +x "$target"
  printf '%s\n' "$command_name" >> "$new_manifest"
  log "criado: $command_name -> $project_dir"
  ((created += 1))
done < "$PROJECTS_FILE"

sort -u "$new_manifest" > "$MANIFEST_FILE"

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
if ! grep -qxF "$PATH_LINE" "$HOME/.bashrc" 2>/dev/null; then
  printf '\n%s\n' "$PATH_LINE" >> "$HOME/.bashrc"
  log 'PATH adicionado ao ~/.bashrc'
fi

export PATH="$TARGET_DIR:$PATH"
hash -r 2>/dev/null || true

printf '\n'
log "instalação concluída: $created comando(s) criado(s), $skipped entrada(s) ignorada(s)."
log "diretório dos comandos: $TARGET_DIR"

if ((created > 0)); then
  printf '\nComandos disponíveis:\n'
  while IFS= read -r command_name; do
    printf '  %-24s %s\n' "$command_name" "$command_name help"
  done < "$MANIFEST_FILE"
fi

printf '\nNo terminal atual, execute:\n  source ~/.bashrc\n'
