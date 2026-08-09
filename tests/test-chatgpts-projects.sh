#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
EXPECTED="$(mktemp)"
ACTUAL="$(mktemp)"
cleanup() { rm -f "$EXPECTED" "$ACTUAL"; }
trap cleanup EXIT

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line="${raw_line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  line="${line#./}"
  line="${line%/}"
  [[ -n "$line" ]] || continue
  basename -- "$line"
done < "$ROOT/config/auto-code-manager.projects" > "$EXPECTED"

"$ROOT/scripts/chatgpts.sh" --list > "$ACTUAL"
diff -u "$EXPECTED" "$ACTUAL"

grep -q 'CHATGPTS_SOURCE=' "$ROOT/deploy/local/install-commands.sh"
grep -q 'for command_name in chromes chatgpts phpstorms' "$ROOT/deploy/local/install-commands.sh"

echo '[test-chatgpts-projects] OK'
