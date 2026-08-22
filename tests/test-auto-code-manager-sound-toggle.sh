#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d /tmp/dev-manager-sound-toggle-test-XXXXXX)"
STATE_DIR="$TEMP_ROOT/state"
FAKE_BIN="$TEMP_ROOT/bin"
SOUND_LOG="$TEMP_ROOT/sound.log"

cleanup() { rm -rf -- "$TEMP_ROOT"; }
trap cleanup EXIT
mkdir -p "$STATE_DIR" "$FAKE_BIN"

cat > "$FAKE_BIN/powershell.exe" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_SOUND_LOG:?}"
exit 0
EOF
chmod +x "$FAKE_BIN/powershell.exe"

touch "$STATE_DIR/dev-manager.sound-disabled"

PATH="$FAKE_BIN:$PATH" TEST_SOUND_LOG="$SOUND_LOG" AUTO_CODE_STATE_DIR="$STATE_DIR" \
  "$PROJECT_ROOT/scripts/auto-code-manager.sh" --test-sound
PATH="$FAKE_BIN:$PATH" TEST_SOUND_LOG="$SOUND_LOG" AUTO_CODE_STATE_DIR="$STATE_DIR" \
  "$PROJECT_ROOT/scripts/auto-code-manager.sh" --test-backup-sound

if [[ -s "$SOUND_LOG" ]]; then
  printf 'FALHOU: som desativado ainda chamou powershell.exe.\n' >&2
  cat "$SOUND_LOG" >&2
  exit 1
fi

printf 'OK: marcador persistente silencia aviso normal e backup\n'
