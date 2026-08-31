#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d /tmp/devauto-runtime-isolation-XXXXXX)"
trap 'rm -rf -- "$T"' EXIT

PARENT="$T/dev-automation"
CHILD="$PARENT/apps/gpt-console"
STATE_DIR="$T/state"
RUNNING_PROJECTS_DIR="$STATE_DIR/running-projects"
mkdir -p "$CHILD" "$RUNNING_PROJECTS_DIR"

source "$ROOT/scripts/dev-manager/60-project-runtime.sh"
log(){ :; }
project_path(){
  case "$1" in
    parent) printf '%s\n' "$PARENT" ;;
    child) printf '%s\n' "$CHILD" ;;
    *) return 1 ;;
  esac
}

make_runtime() {
  local pid="$1" dir="$2" descendants="$3" defer="${4:-0}"
  cat > "$RUNNING_PROJECTS_DIR/$pid.state" <<STATE
PID=$pid
PROJECT_NAME=test-auto
PROJECT_DIR=$dir
DEPLOY_MODE=local
ACTION=setup
AUTO_MODE=1
RESTART_ON_DESCENDANT=$descendants
DEFER_RESTART=$defer
STATE
}

# Shells vivos para que signal_auto_deploys_after_import possa sinalizar de verdade.
trap ':' USR1
sleep 60 & parent_pid=$!
sleep 60 & child_pid=$!
sleep 60 & legacy_desc_pid=$!
cleanup_pids(){
  kill "$parent_pid" "$child_pid" "$legacy_desc_pid" 2>/dev/null || true
}
trap 'cleanup_pids; rm -rf -- "$T"' EXIT

make_runtime "$parent_pid" "$PARENT" 0
make_runtime "$child_pid" "$CHILD" 0
make_runtime "$legacy_desc_pid" "$PARENT" 1

# ZIP do filho: reinicia somente o AUTO do filho; o pai isolado fica quieto.
signal_auto_deploys_after_import child both
[[ -f "$RUNNING_PROJECTS_DIR/$child_pid.state.request" ]]
[[ ! -f "$RUNNING_PROJECTS_DIR/$parent_pid.state.request" ]]
# O estado legado descendants=1 prova que a função ainda respeita a flag quando
# explicitamente usada; o instalador do Dev Manager não deve mais ativá-la.
[[ -f "$RUNNING_PROJECTS_DIR/$legacy_desc_pid.state.request" ]]
rm -f "$RUNNING_PROJECTS_DIR"/*.request

# ZIP do pai: reinicia apenas os AUTOs apontados exatamente para o pai.
signal_auto_deploys_after_import parent both
[[ -f "$RUNNING_PROJECTS_DIR/$parent_pid.state.request" ]]
[[ ! -f "$RUNNING_PROJECTS_DIR/$child_pid.state.request" ]]

# Os dois instaladores do dev-manager-auto precisam fixar descendants=0.
grep -Fq '"dev-manager" "dev-manager" "$PROJECT_ROOT" "0"' "$ROOT/deploy/local/install-dev-manager.sh"
if grep -Fq '[[ "$command_name" == "dev-manager" ]] && restart_descendants=1' "$ROOT/deploy/local/install-commands.sh"; then
  printf 'FALHOU: dev-manager-auto ainda acompanha subprojetos\n' >&2
  exit 1
fi

printf 'OK: AUTO do pai/Dev Manager ignora ZIP de subprojeto; AUTO do filho reinicia de forma independente\n'

# dev-manager-auto deve chamar literalmente o comando global dev-manager pelo PATH.
grep -Fq 'auto_exec_file="dev-manager"' "$ROOT/deploy/local/install-commands.sh"
grep -Fq '"dev-manager" "dev-manager" "$PROJECT_ROOT" "0"' "$ROOT/deploy/local/install-dev-manager.sh"
