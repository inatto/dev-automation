#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d /tmp/install-all-global-test-XXXXXX)"
HOME_DIR="$TEMP_ROOT/home"
TARGET_DIR="$HOME_DIR/.local/bin"
CODE_ROOT="$TEMP_ROOT/Code"
PROJECTS_FILE="$TEMP_ROOT/projects"
LOG_FILE="$TEMP_ROOT/install.log"

cleanup() {
  rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$HOME_DIR" "$CODE_ROOT/orgs/sample-app/deploy/local"
: > "$HOME_DIR/.bashrc"
cat > "$CODE_ROOT/orgs/sample-app/deploy/local/setup.sh" <<'START'
#!/usr/bin/env bash
exit 0
START
chmod +x "$CODE_ROOT/orgs/sample-app/deploy/local/setup.sh"
printf 'orgs/sample-app\n' > "$PROJECTS_FILE"

HOME="$HOME_DIR" \
TARGET_DIR="$TARGET_DIR" \
CODE_ROOT="$CODE_ROOT" \
PROJECTS_FILE="$PROJECTS_FILE" \
  "$PROJECT_ROOT/deploy/local/install-commands.sh" > "$LOG_FILE"

commands=(
  auto-code-manager
  dev-manager
  chromes
  phpstorms
  phpstorm-dev
  oracle-monitor
  sample-app
)

for command_name in "${commands[@]}"; do
  [ -x "$TARGET_DIR/$command_name" ] || {
    printf 'FALHOU: comando global ausente: %s\n' "$command_name" >&2
    cat "$LOG_FILE" >&2
    exit 1
  }
done

grep -Fq 'criado: oracle-monitor' "$LOG_FILE"
grep -Fq 'criado: sample-app' "$LOG_FILE"
printf 'OK: instalador principal atualiza comandos fixos, oracle-monitor e comandos dos projetos\n'
