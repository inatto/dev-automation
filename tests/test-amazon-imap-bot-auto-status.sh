#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
LOCAL_PID=""
REMOTE_PID=""

cleanup() {
  for pid in "$LOCAL_PID" "$REMOTE_PID"; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf -- "$TMP"
}
trap cleanup EXIT

HOME_DIR="$TMP/home"
CODE_ROOT="$TMP/Code"
STATE_DIR="$TMP/state"
PROJECT="$CODE_ROOT/orgs/orbital/orbital-legal"
mkdir -p "$HOME_DIR" "$STATE_DIR" "$PROJECT/deploy/local" "$PROJECT/deploy/remote"
printf 'orgs/orbital/orbital-legal\n' > "$TMP/projects"

for mode in local remote; do
  cat > "$PROJECT/deploy/$mode/setup.sh" <<'SCRIPT'
#!/usr/bin/env bash
trap 'exit 0' INT TERM
while true; do sleep 60; done
SCRIPT
  chmod +x "$PROJECT/deploy/$mode/setup.sh"
done

wait_status() {
  local expected_local="$1" expected_remote="$2" output i
  for i in $(seq 1 100); do
    output="$(HOME="$HOME_DIR" CODE_ROOT="$CODE_ROOT" PROJECTS_FILE="$TMP/projects" \
      AUTO_CODE_STATE_DIR="$STATE_DIR" \
      bash "$ROOT/scripts/amazon-imap-bot-auto-status.sh" "Orbital Legal")"
    if grep -Fxq "Orbital Legal AUTO local: $expected_local" <<< "$output" \
       && grep -Fxq "Orbital Legal AUTO remoto: $expected_remote" <<< "$output"; then
      return 0
    fi
    sleep 0.05
  done
  printf '%s\n' "$output" >&2
  return 1
}

wait_status "NÃO RODANDO" "NÃO RODANDO"

HOME="$HOME_DIR" AUTO_CODE_STATE_DIR="$STATE_DIR" DEV_AUTOMATION_SKIP_CLEAR=1 \
  DEV_AUTOMATION_ERROR_SOUND_ENABLED=0 \
  bash "$ROOT/scripts/project-command.sh" orbital-legal-auto "$PROJECT" local \
  >"$TMP/local.log" 2>&1 &
LOCAL_PID=$!
wait_status "RODANDO" "NÃO RODANDO"

HOME="$HOME_DIR" AUTO_CODE_STATE_DIR="$STATE_DIR" DEV_AUTOMATION_SKIP_CLEAR=1 \
  DEV_AUTOMATION_ERROR_SOUND_ENABLED=0 \
  bash "$ROOT/scripts/project-command.sh" remote-orbital-legal-auto "$PROJECT" remote \
  >"$TMP/remote.log" 2>&1 &
REMOTE_PID=$!
wait_status "RODANDO" "RODANDO"

kill -TERM "$REMOTE_PID"
wait "$REMOTE_PID" 2>/dev/null || true
REMOTE_PID=""
wait_status "RODANDO" "NÃO RODANDO"

printf 'OK: Amazon IMAP Bot detecta AUTO local/remoto por supervisor e PID reais\n'
