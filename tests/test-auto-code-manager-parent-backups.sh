#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SOURCE_ROOT="$PROJECT_ROOT"
TEMP_ROOT="$(mktemp -d /tmp/auto-code-parent-backup-test-XXXXXX)"
TEST_PROJECT="$TEMP_ROOT/dev-automation"
CODE_ROOT="$TEMP_ROOT/Code"
MANAGER="$TEST_PROJECT/scripts/auto-code-manager.sh"
LOG_FILE="$TEMP_ROOT/backup.log"
FAKE_BIN="$TEMP_ROOT/fake-bin"
SOUND_LOG="$TEMP_ROOT/sound.log"
MODULES=(orbital-app orbital-assets orbital-fin orbital-mail orbital-reports)

cleanup() {
  rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT

cp -a -- "$SOURCE_ROOT" "$TEST_PROJECT"
mkdir -p "$CODE_ROOT/orgs/inst-app" "$FAKE_BIN"

cat > "$FAKE_BIN/powershell.exe" <<'PS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_PS_LOG:?}"
exit 0
PS
chmod +x "$FAKE_BIN/powershell.exe"

for module in "${MODULES[@]}"; do
  mkdir -p "$CODE_ROOT/orgs/orbital/$module"
  printf '%s\n' "$module" > "$CODE_ROOT/orgs/orbital/$module/module.txt"
done

printf 'compartilhado\n' > "$CODE_ROOT/orgs/orbital/README-parent.txt"
printf 'inst\n' > "$CODE_ROOT/orgs/inst-app/inst.txt"

cat > "$TEST_PROJECT/config/auto-code-manager.projects" <<'PROJECTS'
orgs/orbital/orbital-app
orgs/orbital/orbital-assets
orgs/orbital/orbital-fin
orgs/orbital/orbital-mail
orgs/orbital/orbital-reports
orgs/inst-app
PROJECTS

: > "$TEST_PROJECT/config/auto-code-manager.ignore-zip"
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"

PATH="$FAKE_BIN:$PATH" \
FAKE_PS_LOG="$SOUND_LOG" \
CODE_ROOT="$CODE_ROOT" \
  "$MANAGER" --backup-once >"$LOG_FILE"

sound_count="$(grep -Fc 'System.Media.SoundPlayer' "$SOUND_LOG" || true)"
if [ "$sound_count" -ne 1 ]; then
  printf 'FALHOU: a rodada deveria tocar ding.wav uma vez, mas tocou %s vez(es).\n' "$sound_count" >&2
  cat "$SOUND_LOG" >&2 || true
  exit 1
fi

EXPECTED_ARCHIVES=(
  orbital-app.zip
  orbital-assets.zip
  orbital-fin.zip
  orbital-mail.zip
  orbital-reports.zip
  inst-app.zip
  orbital.zip
  Code.zip
)

for archive in "${EXPECTED_ARCHIVES[@]}"; do
  if [ ! -s "$CODE_ROOT/$archive" ]; then
    printf 'FALHOU: ZIP ausente: %s\n' "$CODE_ROOT/$archive" >&2
    cat "$LOG_FILE" >&2 || true
    exit 1
  fi
  unzip -tq "$CODE_ROOT/$archive" >/dev/null
  printf 'OK ZIP: %s\n' "$archive"
done

# O ZIP pai contém os cinco ZIPs filhos e os arquivos próprios da pasta pai.
for module in "${MODULES[@]}"; do
  unzip -Z1 "$CODE_ROOT/orbital.zip" | grep -Fxq "$module.zip"

  if unzip -Z1 "$CODE_ROOT/orbital.zip" | grep -q "^$module/"; then
    printf 'FALHOU: orbital.zip duplicou a pasta %s/\n' "$module" >&2
    exit 1
  fi

done
unzip -Z1 "$CODE_ROOT/orbital.zip" | grep -Fxq 'README-parent.txt'

for archive in "${EXPECTED_ARCHIVES[@]}"; do
  [ "$archive" = 'Code.zip' ] && continue
  unzip -Z1 "$CODE_ROOT/Code.zip" | grep -Fxq "$archive"
done

identified="$(CODE_ROOT="$CODE_ROOT" "$MANAGER" --identify-zip orbital.zip)"
[ "$identified" = 'orgs/orbital' ] || {
  printf 'FALHOU: orbital.zip identificado como %s\n' "$identified" >&2
  exit 1
}

printf 'OK: orbital.zip contém os cinco ZIPs filhos, arquivos do pai e está dentro de Code.zip\n'
printf 'OK: ding.wav tocou exatamente uma vez após a rodada completa\n'
