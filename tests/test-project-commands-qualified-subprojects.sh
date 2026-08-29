#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

HOME_DIR="$TMP/home"
CODE_ROOT="$TMP/Code"
TARGET_DIR="$HOME_DIR/.local/bin"
PROJECTS_FILE="$TMP/projects"
RUN_LOG="$TMP/run.log"
mkdir -p "$HOME_DIR" "$TARGET_DIR"
: > "$HOME_DIR/.bashrc"
: > "$RUN_LOG"

cat > "$PROJECTS_FILE" <<'PROJECTS'
bots/dev-automation
bots/dev-automation/apps/exec-agent
infra/amazon-infra
infra/amazon-infra/apps/monitor-app
PROJECTS

make_project() {
  local rel="$1"
  local label="$2"
  local mode
  for mode in local remote; do
    mkdir -p "$CODE_ROOT/$rel/deploy/$mode"
    cat > "$CODE_ROOT/$rel/deploy/$mode/setup.sh" <<SCRIPT
#!/usr/bin/env bash
printf '%s:%s\\n' '$label' '$mode' >> "\${RUN_LOG:?}"
SCRIPT
    chmod +x "$CODE_ROOT/$rel/deploy/$mode/setup.sh"
  done
}

make_project bots/dev-automation dev-automation
make_project bots/dev-automation/apps/exec-agent exec-agent
make_project infra/amazon-infra amazon-infra
make_project infra/amazon-infra/apps/monitor-app monitor-app

HOME="$HOME_DIR" TARGET_DIR="$TARGET_DIR" CODE_ROOT="$CODE_ROOT" PROJECTS_FILE="$PROJECTS_FILE" \
  "$ROOT/deploy/local/install-project-commands.sh" > "$TMP/install.log"

for command_name in \
  dev-automation \
  dev-automation-auto \
  dev-automation--exec-agent \
  dev-automation--exec-agent-auto \
  remote-dev-automation \
  remote-dev-automation-auto \
  remote-dev-automation--exec-agent \
  remote-dev-automation--exec-agent-auto \
  amazon-infra \
  amazon-infra-auto \
  amazon-infra--monitor-app \
  amazon-infra--monitor-app-auto \
  remote-amazon-infra \
  remote-amazon-infra-auto \
  remote-amazon-infra--monitor-app \
  remote-amazon-infra--monitor-app-auto \
  ssh-dev-automation \
  ssh-dev-automation--exec-agent \
  ssh-amazon-infra \
  ssh-amazon-infra--monitor-app; do
  [[ -x "$TARGET_DIR/$command_name" ]] || {
    printf 'FALHOU: comando esperado ausente: %s\n' "$command_name" >&2
    cat "$TMP/install.log" >&2
    exit 1
  }
done

[[ ! -e "$TARGET_DIR/exec-agent" ]]
[[ ! -e "$TARGET_DIR/remote-exec-agent" ]]
[[ ! -e "$TARGET_DIR/monitor-app" ]]
[[ ! -e "$TARGET_DIR/remote-monitor-app" ]]

grep -Fq 'criado: dev-automation--exec-agent ->' "$TMP/install.log"
grep -Fq 'criado: amazon-infra--monitor-app ->' "$TMP/install.log"

RUN_LOG="$RUN_LOG" DEV_AUTOMATION_SKIP_CLEAR=1 "$TARGET_DIR/dev-automation--exec-agent"
RUN_LOG="$RUN_LOG" DEV_AUTOMATION_SKIP_CLEAR=1 "$TARGET_DIR/amazon-infra--monitor-app"
RUN_LOG="$RUN_LOG" DEV_AUTOMATION_SKIP_CLEAR=1 "$TARGET_DIR/remote-dev-automation--exec-agent"
RUN_LOG="$RUN_LOG" DEV_AUTOMATION_SKIP_CLEAR=1 "$TARGET_DIR/remote-amazon-infra--monitor-app"

grep -Fxq 'exec-agent:local' "$RUN_LOG"
grep -Fxq 'monitor-app:local' "$RUN_LOG"
grep -Fxq 'exec-agent:remote' "$RUN_LOG"
grep -Fxq 'monitor-app:remote' "$RUN_LOG"

printf 'OK: comandos globais de subprojetos usam pai--filho e mantêm o destino real do filho\n'
