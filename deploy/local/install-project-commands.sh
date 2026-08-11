#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
PROJECTS_FILE="${PROJECTS_FILE:-$PROJECT_ROOT/config/auto-code-manager.projects}"
COMMAND_RUNNER="${COMMAND_RUNNER:-$PROJECT_ROOT/scripts/project-command.sh}"
ALL_COMMAND_RUNNER="${ALL_COMMAND_RUNNER:-$PROJECT_ROOT/scripts/project-all-command.sh}"
CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
TARGET_DIR="${TARGET_DIR:-$HOME/.local/bin}"
MANIFEST_FILE="$TARGET_DIR/.dev-automation-project-commands"

log() { printf '[project-commands] %s\n' "$*"; }
fail() { printf '[project-commands] ERRO: %s\n' "$*" >&2; exit 1; }

[[ -f "$PROJECTS_FILE" ]] || fail "arquivo de projetos não encontrado: $PROJECTS_FILE"
[[ -f "$COMMAND_RUNNER" ]] || fail "executor não encontrado: $COMMAND_RUNNER"
[[ -f "$ALL_COMMAND_RUNNER" ]] || fail "executor geral não encontrado: $ALL_COMMAND_RUNNER"

chmod +x "$COMMAND_RUNNER" "$ALL_COMMAND_RUNNER"
mkdir -p "$TARGET_DIR"

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

create_command() {
  local command_name="$1"
  local project_dir="$2"
  local deploy_mode="$3"
  local target="$TARGET_DIR/$command_name"

  cat > "$target" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-project-commands
exec "$COMMAND_RUNNER" "$command_name" "$project_dir" "$deploy_mode" "\$@"
EOF_WRAPPER
  chmod +x "$target"
  printf '%s\n' "$command_name" >> "$new_manifest"
  log "criado: $command_name -> $project_dir/deploy/$deploy_mode"
  ((created += 1))
}

create_all_command() {
  local command_name="$1"
  local deploy_mode="$2"
  local target="$TARGET_DIR/$command_name"

  cat > "$target" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-project-commands
exec "$ALL_COMMAND_RUNNER" "$command_name" "$deploy_mode" "$PROJECTS_FILE" "$CODE_ROOT" "$TARGET_DIR" "\$@"
EOF_WRAPPER
  chmod +x "$target"
  printf '%s\n' "$command_name" >> "$new_manifest"
  log "criado: $command_name -> projetos ativos com deploy/$deploy_mode"
  ((created += 1))
}

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line="${raw_line%%#*}"
  line="$(printf '%s' "$line" | xargs)"
  [[ -n "$line" ]] || continue

  project_dir="$CODE_ROOT/$line"
  project_name="$(basename "$line")"

  if [[ ! -d "$project_dir" ]]; then
    log "ignorado; pasta não existe: $project_dir"
    ((skipped += 1))
    continue
  fi

  found=0
  if [[ -f "$project_dir/deploy/local/setup.sh" ]]; then
    create_command "$project_name" "$project_dir" local
    found=1
  fi
  if [[ -f "$project_dir/deploy/remote/setup.sh" ]]; then
    create_command "remote-$project_name" "$project_dir" remote
    found=1
  fi

  if ((found == 0)); then
    log "ignorado; sem deploy local ou remoto com setup.sh: $line"
    ((skipped += 1))
  fi
done < "$PROJECTS_FILE"

create_all_command "local-all" local

create_special_all_command() {
  local command_name="$1"
  local deploy_mode="$2"
  local forced_action="$3"
  local target="$TARGET_DIR/$command_name"

  cat > "$target" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-project-commands
exec "$ALL_COMMAND_RUNNER" "$command_name" "$deploy_mode" "$PROJECTS_FILE" "$CODE_ROOT" "$TARGET_DIR" "$forced_action" "\$@"
EOF_WRAPPER
  chmod +x "$target"
  printf '%s\n' "$command_name" >> "$new_manifest"
  log "criado: $command_name -> ação geral $forced_action ($deploy_mode)"
  ((created += 1))
}

create_special_all_command "local-status-all" local __status
create_special_all_command "local-stop-all" local __stop
create_all_command "remote-all" remote

sort -u "$new_manifest" > "$MANIFEST_FILE"

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
if ! grep -qxF "$PATH_LINE" "$HOME/.bashrc" 2>/dev/null; then
  printf '\n%s\n' "$PATH_LINE" >> "$HOME/.bashrc"
  log 'PATH adicionado ao ~/.bashrc'
fi

export PATH="$TARGET_DIR:$PATH"
hash -r 2>/dev/null || true

log "instalação concluída: $created comando(s) criado(s), $skipped entrada(s) ignorada(s)."
