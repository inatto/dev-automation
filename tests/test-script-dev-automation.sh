#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/script-dev-automation-test-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
CODE="$TMP/Code"
REPO="$CODE/orgs/demo"
BIN="$TMP/bin"
KEY="$TMP/reverse-crypt.key"
PROJECTS="$TMP/projects"
mkdir -p "$REPO/.config/service" "$REPO/apps/empty/.config" "$BIN"
printf 'orgs/demo\norgs/missing\norgs/bundle.zip\n' > "$PROJECTS"
printf 'shared-test-key\n' > "$KEY"
printf 'OPENAI_API_KEY=test-only\n' > "$REPO/.config/service/settings.env"
printf '.config/* filter=git-crypt diff=git-crypt\n' > "$REPO/.gitattributes"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name Test

cat > "$BIN/git-crypt" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"; shift || true
gitdir="$(git rev-parse --git-dir)"
case "$cmd" in
  --version) echo 'git-crypt test' ;;
  unlock)
    [ "${FAIL_UNLOCK:-0}" != 1 ] || exit 9
    mkdir -p "$gitdir/git-crypt/keys"
    cp "$1" "$gitdir/git-crypt/keys/default"
    ;;
  export-key) cp "$gitdir/git-crypt/keys/default" "$1" ;;
  status) exit 0 ;;
  clean|smudge|diff) cat ;;
  *) exit 2 ;;
esac
SH
chmod +x "$BIN/git-crypt"

PATH="$BIN:$PATH" CODE_ROOT="$CODE" PROJECTS_FILE="$PROJECTS" GIT_CRYPT_KEY="$KEY" \
  bash "$ROOT/apps/script-dev-automation/run.sh" --scan-json > "$TMP/before.json"
python3 - "$TMP/before.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["counts"]["projects"] == 1
assert data["counts"]["configs"] == 2
assert data["counts"]["pending"] == 2
assert all(item["configs"] for item in data["projects"])
PY

PATH="$BIN:$PATH" CODE_ROOT="$CODE" PROJECTS_FILE="$PROJECTS" GIT_CRYPT_KEY="$KEY" \
  bash "$ROOT/apps/script-dev-automation/run.sh" --protect-all --yes --scan-json > "$TMP/after.json"
python3 - "$TMP/after.json" <<'PY'
import json, sys
text = open(sys.argv[1], encoding="utf-8").read()
data = json.loads(text[text.index("{"):])
assert data["counts"]["protected"] == 2, data
PY
grep -Fxq '.config/** filter=git-crypt diff=git-crypt' "$REPO/.gitattributes"
grep -Fxq 'apps/empty/.config/** filter=git-crypt diff=git-crypt' "$REPO/.gitattributes"
git -C "$REPO" diff --cached --name-only | grep -Fxq '.gitattributes'
git -C "$REPO" diff --cached --name-only | grep -Fxq '.config/service/settings.env'

printf 'different-key\n' > "$KEY"
PATH="$BIN:$PATH" CODE_ROOT="$CODE" PROJECTS_FILE="$PROJECTS" GIT_CRYPT_KEY="$KEY" \
  bash "$ROOT/apps/script-dev-automation/run.sh" --scan-json > "$TMP/wrong-key.json"
python3 - "$TMP/wrong-key.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["counts"]["wrong_key"] == 2, data
PY

PATH="$BIN:$PATH" CODE_ROOT="$CODE" PROJECTS_FILE="$PROJECTS" GIT_CRYPT_KEY="$KEY" \
  bash "$ROOT/apps/script-dev-automation/run.sh" --correct-project orgs/demo --yes --scan-json > "$TMP/corrected.json"
python3 - "$TMP/corrected.json" <<'PY'
import json, sys
text = open(sys.argv[1], encoding="utf-8").read()
data = json.loads(text[text.index("{"):])
assert data["counts"]["protected"] == 2, data
PY
find "$REPO/.git/script-dev-automation/key-migrations" -name previous.key -type f -print -quit | grep -q .

cp "$KEY" "$TMP/working-key"
printf 'key-that-must-fail\n' > "$KEY"
if FAIL_UNLOCK=1 PATH="$BIN:$PATH" CODE_ROOT="$CODE" PROJECTS_FILE="$PROJECTS" GIT_CRYPT_KEY="$KEY" \
  bash "$ROOT/apps/script-dev-automation/run.sh" --correct-project orgs/demo --yes >/dev/null 2>&1; then
  echo 'a troca deveria falhar para testar o rollback' >&2
  exit 1
fi
PATH="$BIN:$PATH" CODE_ROOT="$CODE" PROJECTS_FILE="$PROJECTS" GIT_CRYPT_KEY="$TMP/working-key" \
  bash "$ROOT/apps/script-dev-automation/run.sh" --scan-json > "$TMP/rollback.json"
python3 - "$TMP/rollback.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["counts"]["protected"] == 2, data
PY

printf 'q' | timeout 8 script -qfec \
  "TERM=xterm-256color PATH='$BIN:$PATH' CODE_ROOT='$CODE' PROJECTS_FILE='$PROJECTS' GIT_CRYPT_KEY='$KEY' bash '$ROOT/apps/script-dev-automation/run.sh'" \
  /dev/null >/dev/null

printf 'OK: Script Dev Automation audita, protege e abre a TUI\n'
