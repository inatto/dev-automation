#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
TARGET_DIR="$HOME_DIR/.local/bin"
CODE_ROOT="$TMP/Code"
mkdir -p "$HOME_DIR" "$CODE_ROOT"
: > "$HOME_DIR/.bashrc"

[[ -x "$ROOT/apps/lrdp/lrdp" ]]
for name in lrdp1 lrdp2; do
  [[ -x "$ROOT/apps/lrdp/$name" ]]
done

! grep -qxF 'bots/lrdp' "$ROOT/config/auto-code-manager.projects"

HOME="$HOME_DIR" TARGET_DIR="$TARGET_DIR" CODE_ROOT="$CODE_ROOT" \
  "$ROOT/deploy/local/install-commands.sh" >/dev/null

[[ -x "$TARGET_DIR/lrdp" ]]
grep -Fq '# generated-by: dev-automation-global-command' "$TARGET_DIR/lrdp"
grep -Fq "$ROOT/apps/lrdp/lrdp" "$TARGET_DIR/lrdp"

for name in lrdp1 lrdp2; do
  [[ -x "$TARGET_DIR/$name" ]]
  grep -Fq '# generated-by: dev-automation-global-command' "$TARGET_DIR/$name"
  grep -Fq "$ROOT/apps/lrdp/$name" "$TARGET_DIR/$name"
done

printf 'OK: lrdp TUI + lrdp1/lrdp2 integrados em dev-automation/apps/lrdp e instalados globalmente\n'
