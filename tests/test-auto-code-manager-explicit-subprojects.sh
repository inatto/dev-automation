#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP="$(mktemp -d /tmp/auto-code-explicit-subprojects-XXXXXX)"
TEST_PROJECT="$TEMP/dev-automation"
CODE_ROOT="$TEMP/Code"
FAKE_BIN="$TEMP/fake-bin"
trap 'rm -rf -- "$TEMP"' EXIT

cp -a -- "$ROOT" "$TEST_PROJECT"
mkdir -p "$FAKE_BIN" \
  "$CODE_ROOT/bots/dev-automation/apps/exec-agent" \
  "$CODE_ROOT/bots/dev-automation/apps/dev-status" \
  "$CODE_ROOT/bots/dev-automation/apps/oracle-monitor"
cat > "$FAKE_BIN/powershell.exe" <<'PS'
#!/usr/bin/env bash
exit 0
PS
chmod +x "$FAKE_BIN/powershell.exe"
printf 'pai\n' > "$CODE_ROOT/bots/dev-automation/root.txt"
printf 'exec\n' > "$CODE_ROOT/bots/dev-automation/apps/exec-agent/exec.txt"
printf 'status\n' > "$CODE_ROOT/bots/dev-automation/apps/dev-status/status.txt"
printf 'oracle\n' > "$CODE_ROOT/bots/dev-automation/apps/oracle-monitor/oracle.txt"

cat > "$TEST_PROJECT/config/auto-code-manager.projects" <<'PROJECTS'
bots/dev-automation
bots/dev-automation/apps/exec-agent
PROJECTS
cat > "$TEST_PROJECT/config/auto-code-manager.ignore-zip" <<'SAFE_IGNORE'
.git/
.venv/
venv/
node_modules/
SAFE_IGNORE
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"

PATH="$FAKE_BIN:$PATH" CODE_ROOT="$CODE_ROOT" "$TEST_PROJECT/scripts/auto-code-manager.sh" --backup-once >/dev/null

[ -s "$CODE_ROOT/dev-automation.zip" ]
[ -s "$CODE_ROOT/dev-automation--exec-agent.zip" ]
[ ! -e "$CODE_ROOT/apps.zip" ]
[ ! -e "$CODE_ROOT/Code.zip" ]
! unzip -Z1 "$CODE_ROOT/dev-automation.zip" | grep -q '^apps/exec-agent/'
unzip -Z1 "$CODE_ROOT/dev-automation.zip" | grep -Fxq 'apps/dev-status/status.txt'
unzip -Z1 "$CODE_ROOT/dev-automation.zip" | grep -Fxq 'apps/oracle-monitor/oracle.txt'
unzip -p "$CODE_ROOT/dev-automation--exec-agent.zip" exec.txt | grep -Fxq 'exec'

[ "$(CODE_ROOT="$CODE_ROOT" "$TEST_PROJECT/scripts/auto-code-manager.sh" --identify-zip exec-agent.zip)" = 'bots/dev-automation/apps/exec-agent' ]
[ "$(CODE_ROOT="$CODE_ROOT" "$TEST_PROJECT/scripts/auto-code-manager.sh" --identify-zip exec-agent-incremental.zip)" = 'bots/dev-automation/apps/exec-agent' ]
[ "$(CODE_ROOT="$CODE_ROOT" "$TEST_PROJECT/scripts/auto-code-manager.sh" --identify-zip dev-automation--exec-agent.zip)" = 'bots/dev-automation/apps/exec-agent' ]

cat > "$TEST_PROJECT/config/auto-code-manager.projects" <<'PROJECTS'
bots/dev-automation
bots/dev-automation/apps/exec-agent
bots/dev-automation/apps.zip
Code.zip
PROJECTS
PATH="$FAKE_BIN:$PATH" CODE_ROOT="$CODE_ROOT" "$TEST_PROJECT/scripts/auto-code-manager.sh" --backup-once >/dev/null

[ "$(unzip -Z1 "$CODE_ROOT/apps.zip")" = 'dev-automation--exec-agent.zip' ]
code_entries="$(unzip -Z1 "$CODE_ROOT/Code.zip" | sort)"
[ "$code_entries" = $'apps.zip\ndev-automation.zip' ] || {
  printf 'FALHOU: Code.zip inesperado:\n%s\n' "$code_entries" >&2
  exit 1
}

printf 'OK: subprojeto cadastrado não duplica no pai; agregadores só existem quando explicitados\n'
