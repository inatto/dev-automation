#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
FAKE_BIN="$(mktemp -d)"
FAKE_LOG="$(mktemp)"
trap 'rm -rf "$FAKE_BIN" "$FAKE_LOG"' EXIT

cat > "$FAKE_BIN/powershell.exe" <<'PS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_PS_LOG:?}"
exit 0
PS
chmod +x "$FAKE_BIN/powershell.exe"

PATH="$FAKE_BIN:$PATH" \
FAKE_PS_LOG="$FAKE_LOG" \
  "$PROJECT_ROOT/scripts/auto-code-manager.sh" --test-backup-sound

grep -Fq 'C:\Windows\Media\ding.wav' "$FAKE_LOG"
grep -Fq 'System.Media.SoundPlayer' "$FAKE_LOG"
grep -Fq 'PlaySync()' "$FAKE_LOG"

if grep -Fqi '[console]::beep' "$FAKE_LOG"; then
  echo 'ERRO: o aviso principal de backup ainda usa beep eletrônico.' >&2
  exit 1
fi

echo 'OK: backup usa C:\Windows\Media\ding.wav via SoundPlayer'
