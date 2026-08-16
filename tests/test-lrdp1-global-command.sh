#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
TARGET_DIR="$HOME_DIR/.local/bin"
CODE_ROOT="$TMP/Code"
LRDP_DIR="$CODE_ROOT/bots/lrdp"
mkdir -p "$HOME_DIR" "$LRDP_DIR"
: > "$HOME_DIR/.bashrc"

for name in lrdp1 lrdp2; do
  cat > "$LRDP_DIR/$name" <<SCRIPT
#!/usr/bin/env bash
printf '$name:%s\\n' "\$*"
SCRIPT
  chmod +x "$LRDP_DIR/$name"
done

HOME="$HOME_DIR" TARGET_DIR="$TARGET_DIR" CODE_ROOT="$CODE_ROOT" \
  "$ROOT/deploy/local/install-commands.sh" >/dev/null

for name in lrdp1 lrdp2; do
  [[ -x "$TARGET_DIR/$name" ]]
  grep -Fq '# generated-by: dev-automation-global-command' "$TARGET_DIR/$name"
  grep -Fq "$LRDP_DIR/$name" "$TARGET_DIR/$name"
  output="$("$TARGET_DIR/$name" alpha beta)"
  [[ "$output" == "$name:alpha beta" ]]
done

printf 'OK: lrdp1 e lrdp2 autocontidos instalados como comandos globais pelo dev-manager/install-commands\n'
