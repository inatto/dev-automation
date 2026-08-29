#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP="$(mktemp -d /tmp/auto-code-project-key-XXXXXX)"
TEST_PROJECT="$TEMP/dev-automation"
CODE_ROOT="$TEMP/Code"
FAKE_BIN="$TEMP/fake-bin"
LOG="$TEMP/run.log"
trap 'rm -rf -- "$TEMP"' EXIT

cp -a -- "$ROOT" "$TEST_PROJECT"
mkdir -p "$FAKE_BIN" \
  "$CODE_ROOT/orgs/alpha/apps/exec-agent" \
  "$CODE_ROOT/orgs/beta/tools/exec-agent"
cat > "$FAKE_BIN/powershell.exe" <<'PS'
#!/usr/bin/env bash
exit 0
PS
chmod +x "$FAKE_BIN/powershell.exe"
printf 'alpha\n' > "$CODE_ROOT/orgs/alpha/apps/exec-agent/a.txt"
printf 'beta\n' > "$CODE_ROOT/orgs/beta/tools/exec-agent/b.txt"

cat > "$TEST_PROJECT/config/projects/default.projects" <<'PROJECTS'
orgs/alpha/apps/exec-agent
orgs/beta/tools/exec-agent
PROJECTS
: > "$TEST_PROJECT/config/auto-code-manager.ignore-zip"
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"

if PATH="$FAKE_BIN:$PATH" CODE_ROOT="$CODE_ROOT" "$TEST_PROJECT/scripts/auto-code-manager.sh" --backup-once >"$LOG" 2>&1; then
  printf 'FALHOU: nomes lógicos duplicados deveriam impedir o dev-manager/backup.\n' >&2
  cat "$LOG" >&2
  exit 1
fi

grep -Fq "nome lógico de projeto duplicado 'exec-agent'" "$LOG"
grep -Fq 'Nomes lógicos de projeto são chave única global' "$LOG"
[ ! -e "$CODE_ROOT/exec-agent.zip" ]

printf 'OK: nome lógico duplicado bloqueia a execução independentemente do projeto pai\n'
