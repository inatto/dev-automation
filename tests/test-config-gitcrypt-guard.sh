#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
GUARD="$ROOT/scripts/config-gitcrypt-guard.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CODE="$TMP/Code"; REPO="$CODE/orgs/demo"; BIN="$TMP/bin"; KEY="$TMP/key"
mkdir -p "$REPO/config" "$BIN"
printf 'secret\n' > "$REPO/config/app.env"
printf 'dummy-key\n' > "$KEY"
printf 'orgs/demo\n' > "$TMP/projects"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test

# Stub git-crypt: unlock records the exact key; export-key works after unlock.
cat > "$BIN/git-crypt" <<'SH'
#!/usr/bin/env bash
set -e
cmd="${1:-}"; shift || true
case "$cmd" in
  unlock)
    cp "$1" .git/mock-gitcrypt-key
    printf '%s\n' "$1" > .git/mock-unlock-arg
    ;;
  export-key)
    [ -f .git/mock-gitcrypt-key ] || exit 1
    cp .git/mock-gitcrypt-key "$1"
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$BIN/git-crypt"

# git invokes git-crypt from repo cwd; make PATH pick the stub.
PATH="$BIN:$PATH" "$GUARD" --unlock --code-root "$CODE" --projects-file "$TMP/projects" --key "$KEY" > "$TMP/out" 2>&1

grep -Fq 'UNLOCK:' "$TMP/out"
test -f "$REPO/.git/mock-unlock-arg"
grep -Fxq "$KEY" "$REPO/.git/mock-unlock-arg"

# Critical invariant: project tree stays untouched by the guard.
test ! -e "$REPO/.gitattributes"
test ! -e "$REPO/.git/info/attributes"
[ "$(git -C "$REPO" status --porcelain --untracked-files=all | sort)" = '?? config/app.env' ]

# Second run is idempotent and does not call unlock again; still no project files.
rm -f "$REPO/.git/mock-unlock-arg"
PATH="$BIN:$PATH" "$GUARD" --unlock --code-root "$CODE" --projects-file "$TMP/projects" --key "$KEY" > "$TMP/out2" 2>&1
grep -Fq 'já desbloqueado com a chave padrão' "$TMP/out2"
test ! -e "$REPO/.git/mock-unlock-arg"
test ! -e "$REPO/.gitattributes"
test ! -e "$REPO/.git/info/attributes"

# --fix must be dead, not a hidden alias.
if PATH="$BIN:$PATH" "$GUARD" --fix --code-root "$CODE" --projects-file "$TMP/projects" --key "$KEY" >/dev/null 2>&1; then
  echo '--fix deveria falhar' >&2; exit 1
fi

echo 'OK: git-crypt guard somente unlock, sem gitattributes/index'
