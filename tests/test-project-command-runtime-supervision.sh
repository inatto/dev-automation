#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP="$(mktemp -d /tmp/project-command-runtime-XXXXXX)"
APP="$TEMP/app"
STATE="$TEMP/state"
SOUND_LOG="$TEMP/error-sound.log"
PID=""

cleanup() {
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf -- "$TEMP"
}
trap cleanup EXIT

mkdir -p "$APP/deploy/local" "$STATE"
cat > "$APP/deploy/local/setup.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
COUNT_FILE="${TEST_COUNT_FILE:?}"
n=0
[[ ! -f "$COUNT_FILE" ]] || n="$(cat "$COUNT_FILE")"
printf '%d\n' "$((n + 1))" > "$COUNT_FILE"
trap 'exit 0' TERM INT
while true; do sleep 0.1; done
SCRIPT
cat > "$APP/deploy/local/fail.sh" <<'SCRIPT'
#!/usr/bin/env bash
exit 7
SCRIPT
chmod +x "$APP/deploy/local/setup.sh" "$APP/deploy/local/fail.sh"

cat > "$TEMP/fake-auto-manager.sh" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_SOUND_LOG:?}"
exit 0
SCRIPT
chmod +x "$TEMP/fake-auto-manager.sh"

COUNT_FILE="$TEMP/count"
AUTO_CODE_STATE_DIR="$STATE" TEST_COUNT_FILE="$COUNT_FILE" DEV_AUTOMATION_ERROR_SOUND_ENABLED=0 \
  "$ROOT/scripts/project-command.sh" sample "$APP" local setup >"$TEMP/run.log" 2>&1 &
PID=$!

wait_until() {
  local want="$1" i
  for i in $(seq 1 100); do
    [[ "$(cat "$COUNT_FILE" 2>/dev/null || true)" == "$want" ]] && return 0
    sleep 0.05
  done
  cat "$TEMP/run.log" >&2
  return 1
}

wait_until 1
state_file="$(find "$STATE/running-projects" -maxdepth 1 -type f -name '*.state' -print -quit)"
[[ -n "$state_file" ]]
kill -USR1 "$PID"
wait_until 2
sleep 0.3
[[ "$(cat "$COUNT_FILE")" == 2 ]]

kill -TERM "$PID"
wait "$PID" 2>/dev/null || true
PID=""
[[ ! -e "$state_file" ]]

auto_status=0
AUTO_CODE_STATE_DIR="$STATE" TEST_SOUND_LOG="$SOUND_LOG" DEV_AUTOMATION_AUTO_MANAGER="$TEMP/fake-auto-manager.sh" \
  "$ROOT/scripts/project-command.sh" sample "$APP" local fail >/dev/null 2>&1 || auto_status=$?
[[ "$auto_status" -eq 7 ]]
grep -Fxq -- '--error-sound' "$SOUND_LOG"

printf 'OK: comando local registra runtime, reinicia uma vez por USR1 e toca som em erro\n'
