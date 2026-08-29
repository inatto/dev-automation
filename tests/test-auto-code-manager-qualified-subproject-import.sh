#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP="$(mktemp -d /tmp/auto-code-qualified-import-XXXXXX)"
TEST_PROJECT="$TEMP/dev-automation"
CODE_ROOT="$TEMP/Code"
FAKE_BIN="$TEMP/fake-bin"
INBOX="$TEMP/inbox"
trap 'rm -rf -- "$TEMP"' EXIT

cp -a -- "$ROOT" "$TEST_PROJECT"
mkdir -p "$FAKE_BIN" "$INBOX" \
  "$CODE_ROOT/bots/dev-automation/apps/exec-agent"
cat > "$FAKE_BIN/powershell.exe" <<'PS'
#!/usr/bin/env bash
exit 0
PS
chmod +x "$FAKE_BIN/powershell.exe"
printf 'old\n' > "$CODE_ROOT/bots/dev-automation/apps/exec-agent/value.txt"

cat > "$TEST_PROJECT/config/projects/default.projects" <<'PROJECTS'
bots/dev-automation
bots/dev-automation/apps/exec-agent
PROJECTS
: > "$TEST_PROJECT/config/auto-code-manager.ignore-zip"
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"
cat > "$TEST_PROJECT/config/auto-code-manager.env" <<'ENV'
STABLE_WAIT=1
BACKUP_EVERY=20
ENV

mkdir -p "$TEMP/pkg-short/exec-agent"
printf 'short\n' > "$TEMP/pkg-short/exec-agent/value.txt"
(cd "$TEMP/pkg-short" && zip -qr "$INBOX/exec-agent-incremental.zip" exec-agent)
PATH="$FAKE_BIN:$PATH" CODE_ROOT="$CODE_ROOT" DEV_MANAGER_PROJECTS_FILE="$TEST_PROJECT/config/projects/default.projects" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" --import-one "$INBOX/exec-agent-incremental.zip" >/dev/null
grep -Fxq 'short' "$CODE_ROOT/bots/dev-automation/apps/exec-agent/value.txt"
[ ! -e "$INBOX/exec-agent-incremental.zip" ]

mkdir -p "$TEMP/pkg-qualified/apps/exec-agent"
printf 'qualified\n' > "$TEMP/pkg-qualified/apps/exec-agent/value.txt"
(cd "$TEMP/pkg-qualified" && zip -qr "$INBOX/dev-automation-exec-agent.zip" apps/exec-agent)
PATH="$FAKE_BIN:$PATH" CODE_ROOT="$CODE_ROOT" DEV_MANAGER_PROJECTS_FILE="$TEST_PROJECT/config/projects/default.projects" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" --import-one "$INBOX/dev-automation-exec-agent.zip" >/dev/null
grep -Fxq 'qualified' "$CODE_ROOT/bots/dev-automation/apps/exec-agent/value.txt"
[ ! -e "$INBOX/dev-automation-exec-agent.zip" ]

mkdir -p "$TEMP/pkg-legacy/dev-automation--exec-agent"
printf 'legacy\n' > "$TEMP/pkg-legacy/dev-automation--exec-agent/value.txt"
(cd "$TEMP/pkg-legacy" && zip -qr "$INBOX/dev-automation--exec-agent.zip" dev-automation--exec-agent)
PATH="$FAKE_BIN:$PATH" CODE_ROOT="$CODE_ROOT" DEV_MANAGER_PROJECTS_FILE="$TEST_PROJECT/config/projects/default.projects" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" --import-one "$INBOX/dev-automation--exec-agent.zip" >/dev/null
grep -Fxq 'legacy' "$CODE_ROOT/bots/dev-automation/apps/exec-agent/value.txt"
[ ! -e "$INBOX/dev-automation--exec-agent.zip" ]

printf 'OK: ZIP curto, hierárquico atual e qualificado legado importam no mesmo subprojeto\n'
