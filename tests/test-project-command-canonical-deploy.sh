#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/project-command-canonical-XXXXXX)"
PID=""
cleanup(){ if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then kill -TERM "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi; rm -rf -- "$TMP"; }
trap cleanup EXIT
APP="$TMP/app"; STATE="$TMP/state"; mkdir -p "$APP/deploy/local" "$STATE"
cat > "$APP/deploy/local/setup.sh" <<'SCRIPT'
#!/usr/bin/env bash
printf 'setup\n' >> "${RUN_LOG:?}"
trap 'exit 0' TERM INT
while true; do sleep .05; done
SCRIPT
cat > "$APP/deploy/local/setup-api.sh" <<'SCRIPT'
#!/usr/bin/env bash
printf 'api-direct\n' >> "${RUN_LOG:?}"
while true; do sleep .05; done
SCRIPT
cat > "$APP/deploy/local/setup-web.sh" <<'SCRIPT'
#!/usr/bin/env bash
printf 'web-direct\n' >> "${RUN_LOG:?}"
while true; do sleep .05; done
SCRIPT
chmod +x "$APP/deploy/local/"*.sh
RUN_LOG="$TMP/run.log" AUTO_CODE_STATE_DIR="$STATE" DEV_AUTOMATION_ERROR_SOUND_ENABLED=0 "$ROOT/scripts/project/project-command.sh" sample-auto "$APP" local setup >"$TMP/out" 2>&1 & PID=$!
for _ in $(seq 1 100); do [[ -s "$TMP/run.log" ]] && break; sleep .03; done
grep -Fxq setup "$TMP/run.log"
! grep -q 'api-direct\|web-direct' "$TMP/run.log"
state="$(find "$STATE/running-projects" -name '*.state' -print -quit)"
grep -Fxq 'MODE=single' "$state"
printf 'both\n' > "$state.request"
kill -USR1 "$PID"
for _ in $(seq 1 100); do [[ "$(grep -c '^setup$' "$TMP/run.log")" -ge 2 ]] && break; sleep .03; done
[[ "$(grep -c '^setup$' "$TMP/run.log")" -eq 2 ]]
! grep -q 'api-direct\|web-direct' "$TMP/run.log"
kill -TERM "$PID"; wait "$PID" 2>/dev/null || true; PID=""
echo 'OK: AUTO preserva setup.sh canônico e reinicia o deploy completo.'
