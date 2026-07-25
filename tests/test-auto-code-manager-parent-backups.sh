#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SOURCE_ROOT="$PROJECT_ROOT"
TEMP_ROOT="$(mktemp -d /tmp/auto-code-parent-backup-test-XXXXXX)"
TEST_PROJECT="$TEMP_ROOT/dev-automation"
CODE_ROOT="$TEMP_ROOT/Code"
MANAGER="$TEST_PROJECT/scripts/auto-code-manager.sh"

cleanup() {
  rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT

cp -a -- "$SOURCE_ROOT" "$TEST_PROJECT"
mkdir -p \
  "$CODE_ROOT/orgs/orbital/orbital-app" \
  "$CODE_ROOT/orgs/orbital/orbital-assets" \
  "$CODE_ROOT/orgs/inst-app"

printf 'app\n' > "$CODE_ROOT/orgs/orbital/orbital-app/app.txt"
printf 'assets\n' > "$CODE_ROOT/orgs/orbital/orbital-assets/assets.txt"
printf 'inst\n' > "$CODE_ROOT/orgs/inst-app/inst.txt"

cat > "$TEST_PROJECT/config/auto-code-manager.projects" <<'PROJECTS'
orgs/orbital/orbital-app
orgs/orbital/orbital-assets
orgs/inst-app
PROJECTS

: > "$TEST_PROJECT/config/auto-code-manager.ignore-zip"
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"

CODE_ROOT="$CODE_ROOT" "$MANAGER" --backup-once >/tmp/auto-code-parent-backup-test.log

for archive in orbital-app.zip orbital-assets.zip inst-app.zip orbital.zip Code.zip; do
  if [ ! -s "$CODE_ROOT/$archive" ]; then
    printf 'FALHOU: ZIP ausente: %s\n' "$CODE_ROOT/$archive" >&2
    cat /tmp/auto-code-parent-backup-test.log >&2 || true
    exit 1
  fi
  unzip -tq "$CODE_ROOT/$archive" >/dev/null
  printf 'OK ZIP: %s\n' "$archive"
done

unzip -Z1 "$CODE_ROOT/orbital.zip" | grep -Fxq 'orbital-app/app.txt'
unzip -Z1 "$CODE_ROOT/orbital.zip" | grep -Fxq 'orbital-assets/assets.txt'

if unzip -Z1 "$CODE_ROOT/orbital.zip" | grep -q '^orbital/'; then
  echo 'FALHOU: orbital.zip contém pasta-wrapper orbital/' >&2
  exit 1
fi

for archive in orbital-app.zip orbital-assets.zip inst-app.zip orbital.zip; do
  unzip -Z1 "$CODE_ROOT/Code.zip" | grep -Fxq "$archive"
done

identified="$(CODE_ROOT="$CODE_ROOT" "$MANAGER" --identify-zip orbital.zip)"
[ "$identified" = 'orgs/orbital' ] || {
  printf 'FALHOU: orbital.zip identificado como %s\n' "$identified" >&2
  exit 1
}

printf 'OK: orbital.zip contém os módulos diretamente e está dentro de Code.zip\n'
