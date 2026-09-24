#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP="$(mktemp -d /tmp/auto-code-skills-md-XXXXXX)"
TEST_PROJECT="$TEMP/dev-automation"
CODE_ROOT="$TEMP/Code"
FAKE_BIN="$TEMP/fake-bin"
trap 'rm -rf -- "$TEMP"' EXIT

cp -a -- "$ROOT" "$TEST_PROJECT"
mkdir -p "$FAKE_BIN" "$TEST_PROJECT/skills/sub" "$CODE_ROOT/apps/sample-app"
cat > "$FAKE_BIN/powershell.exe" <<'PS'
#!/usr/bin/env bash
exit 0
PS
chmod +x "$FAKE_BIN/powershell.exe"
printf 'regra ui\n' > "$TEST_PROJECT/skills/ui.txt"
printf 'regra geral\n' > "$TEST_PROJECT/skills/sub/general.txt"
printf 'app\n' > "$CODE_ROOT/apps/sample-app/app.txt"

cat > "$TEST_PROJECT/config/projects/default.projects" <<'PROJECTS'
apps/sample-app
apps.zip
PROJECTS
cat > "$TEST_PROJECT/config/auto-code-manager.ignore-zip" <<'IGNORE'
.git/
.venv/
venv/
node_modules/
IGNORE
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"

PATH="$FAKE_BIN:$PATH" CODE_ROOT="$CODE_ROOT" DEV_MANAGER_PROJECTS_FILE="$TEST_PROJECT/config/projects/default.projects" \
  "$TEST_PROJECT/scripts/dev-manager/auto-code-manager.sh" --backup-once >/dev/null

for zip_file in "$CODE_ROOT/sample-app.zip" "$CODE_ROOT/apps.zip"; do
  unzip -Z1 "$zip_file" | grep -Fxq 'skills.md'
  content="$(unzip -p "$zip_file" skills.md)"
  printf '%s\n' "$content" | grep -Fxq '# sub/general.txt'
  printf '%s\n' "$content" | grep -Fxq 'regra geral'
  printf '%s\n' "$content" | grep -Fxq '# ui.txt'
  printf '%s\n' "$content" | grep -Fxq 'regra ui'
done

[ ! -e "$CODE_ROOT/apps/sample-app/skills.md" ]
printf 'OK: todo backup normal/agregador recebe skills.md consolidado na raiz\n'
