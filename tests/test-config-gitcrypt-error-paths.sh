#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
GUARD="$ROOT/scripts/config-gitcrypt-guard.sh"
TMP="$(mktemp -d /tmp/gitcrypt-error-paths-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
BIN="$TMP/bin"
CODE="$TMP/Code"
REPO="$CODE/bots/general-crawler"
KEY="$TMP/key"
PROJECTS="$TMP/projects"
mkdir -p "$BIN" "$REPO/config/local" "$REPO/apps/api/config/production"
printf 'same-key\n' > "$KEY"
printf 'bots/general-crawler\n' > "$PROJECTS"

cat > "$BIN/git-crypt" <<'EOF_FAKE'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"; shift || true
gitdir="$(git rev-parse --git-dir)"
case "$cmd" in
  export-key)
    cp "$gitdir/git-crypt/keys/default" "$1"
    ;;
  *) exit 2 ;;
esac
EOF_FAKE
chmod +x "$BIN/git-crypt"
export PATH="$BIN:$PATH"

git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name Test
printf 'LOCAL=1\n' > "$REPO/config/local/app.env"
printf 'LOCAL=2\n' > "$REPO/config/local/db.conf"
printf 'PROD=1\n' > "$REPO/apps/api/config/production/app.env"
printf 'PROD=2\n' > "$REPO/apps/api/config/production/db.conf"
git -C "$REPO" add .
git -C "$REPO" commit -qm init
mkdir -p "$REPO/.git/git-crypt/keys"
cp "$KEY" "$REPO/.git/git-crypt/keys/default"

set +e
"$GUARD" --check --code-root "$CODE" --projects-file "$PROJECTS" --key "$KEY" > "$TMP/out.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 3 ]

grep -Fq "CRITICAL: $REPO: 4 arquivo(s) rastreado(s) em config sem atributos git-crypt corretos" "$TMP/out.log"
grep -Fq "DETALHE:   pasta config: $REPO/config" "$TMP/out.log"
grep -Fq "DETALHE:     - $REPO/config/local/app.env [filter=unspecified, diff=unspecified]" "$TMP/out.log"
grep -Fq "DETALHE:     - $REPO/config/local/db.conf [filter=unspecified, diff=unspecified]" "$TMP/out.log"
grep -Fq "DETALHE:   pasta config: $REPO/apps/api/config" "$TMP/out.log"
grep -Fq "DETALHE:     - $REPO/apps/api/config/production/app.env [filter=unspecified, diff=unspecified]" "$TMP/out.log"
grep -Fq "DETALHE:     - $REPO/apps/api/config/production/db.conf [filter=unspecified, diff=unspecified]" "$TMP/out.log"

printf 'OK: erro git-crypt lista cada pasta config e cada arquivo problemático\n'
