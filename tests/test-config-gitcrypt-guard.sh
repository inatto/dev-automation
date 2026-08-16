#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
GUARD="$ROOT/scripts/config-gitcrypt-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
CODE="$TMP/Code"
KEY="$TMP/git-reverse-crypt-2.key"
PROJECTS="$TMP/projects"
mkdir -p "$BIN" "$CODE/orgs/test/config"
printf 'standard-shared-key-v1\n' > "$KEY"
printf 'orgs/test\n' > "$PROJECTS"

# Fake mínimo de git-crypt para testar contrato sem depender do pacote do host.
cat > "$BIN/git-crypt" <<'EOF_FAKE'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"; shift || true
gitdir="$(git rev-parse --git-dir)"
keypath="$gitdir/git-crypt/keys/default"
case "$cmd" in
  unlock)
    mkdir -p "$(dirname "$keypath")"
    cp "$1" "$keypath"
    git config filter.git-crypt.clean 'git-crypt clean'
    git config filter.git-crypt.smudge 'git-crypt smudge'
    git config filter.git-crypt.required true
    git config diff.git-crypt.textconv 'git-crypt diff'
    ;;
  export-key)
    [ -f "$keypath" ] || exit 1
    cp "$keypath" "$1"
    ;;
  clean)
    printf '\0GITCRYPT\0'; cat ;;
  smudge)
    python3 -c 'import sys; d=sys.stdin.buffer.read(); h=b"\0GITCRYPT\0"; sys.stdout.buffer.write(d[len(h):] if d.startswith(h) else d)' ;;
  diff) cat "${1:-/dev/stdin}" 2>/dev/null || cat ;;
  status)
    if [ "${1:-}" = -f ] || [ "${1:-}" = --fix ]; then shift; git add --renormalize -- "$@"; fi
    ;;
  *) exit 2 ;;
esac
EOF_FAKE
chmod +x "$BIN/git-crypt"
export PATH="$BIN:$PATH"

cd "$CODE/orgs/test"
git init -q
git config user.email test@example.com
git config user.name Test
printf 'PASSWORD=plaintext\n' > config/app.env
git add config/app.env
git commit -qm initial

set +e
PATH="$BIN:$PATH" "$GUARD" --fix --code-root "$CODE" --projects-file "$PROJECTS" --key "$KEY" > "$TMP/first.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] # HEAD antigo vira aviso; índice atual é reparado automaticamente.
grep -Fq 'FIX: git-crypt configurado/desbloqueado' "$TMP/first.log"
grep -Fq 'FIX: regras git-crypt adicionadas/normalizadas' "$TMP/first.log"
grep -Fq 'HEAD antigo; índice já está criptografado' "$TMP/first.log"
grep -Fq 'config/** filter=git-crypt diff=git-crypt' .gitattributes
grep -Fq '**/.gitignore !filter !diff' .gitattributes
[ "$(git show :config/app.env | head -c 10 | od -An -tx1 | tr -d ' \n')" = '00474954435259505400' ]

# Depois de commitada a proteção, executar novamente é idempotente e limpo.
git commit -qm 'protect config'
PATH="$BIN:$PATH" "$GUARD" --fix --code-root "$CODE" --projects-file "$PROJECTS" --key "$KEY" > "$TMP/second.log" 2>&1
grep -Fq 'RESUMO: 0 críticos, 0 correção(ões)' "$TMP/second.log"
[ -z "$(git status --porcelain)" ]

# Config modificada/staged continua com o MESMO estado de trabalho: o guard
# transforma somente o blob já existente no índice, nunca usa o working tree.
printf 'PASSWORD=staged-user-change\n' > config/app.env
git add -- config/app.env
# Simula índice plaintext legado mantendo o conteúdo staged do usuário.
plain_blob="$(printf 'PASSWORD=staged-user-change\n' | git hash-object -w --stdin)"
git update-index --cacheinfo 100644 "$plain_blob" config/app.env
printf 'PASSWORD=unstaged-user-change\n' > config/app.env
before_worktree="$(cat config/app.env)"
PATH="$BIN:$PATH" "$GUARD" --fix --code-root "$CODE" --projects-file "$PROJECTS" --key "$KEY" > "$TMP/dirty.log" 2>&1
grep -Fq 'blob(s) config migrado(s) para git-crypt no índice sem tocar no working tree' "$TMP/dirty.log"
[ "$(cat config/app.env)" = "$before_worktree" ]
[ "$(git show :config/app.env | head -c 10 | od -An -tx1 | tr -d ' \n')" = '00474954435259505400' ]
# O staged continua representando staged-user-change, e o working tree continua
# unstaged-user-change após o smudge do fake.
[ "$(git show :config/app.env | PATH="$BIN:$PATH" git-crypt smudge)" = 'PASSWORD=staged-user-change' ]
[ "$(cat config/app.env)" = 'PASSWORD=unstaged-user-change' ]
# Restaura para testar chave divergente sem ruído do working tree.
git checkout -- config/app.env
git reset -q HEAD -- config/app.env

# Chave local diferente nunca é substituída automaticamente.
printf 'different-key\n' > "$TMP/other.key"
cp "$TMP/other.key" .git/git-crypt/keys/default
set +e
PATH="$BIN:$PATH" "$GUARD" --fix --code-root "$CODE" --projects-file "$PROJECTS" --key "$KEY" > "$TMP/different.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 3 ]
grep -Fq 'chave git-crypt diferente' "$TMP/different.log"
cmp -s "$TMP/other.key" .git/git-crypt/keys/default

# Se git-crypt não estiver instalado, o erro mostra o comando exato de instalação.
set +e
PATH="/usr/bin:/bin" "$GUARD" --fix --code-root "$CODE" --projects-file "$PROJECTS" --key "$KEY" > "$TMP/missing.log" 2>&1
rc=$?
set -e
if ! command -v git-crypt >/dev/null 2>&1; then
  [ "$rc" -eq 3 ]
  grep -Fq 'INSTALAR: sudo apt update && sudo apt install -y git-crypt' "$TMP/missing.log"
fi

printf 'OK: guard config git-crypt aplica chave padrão, criptografa índice, é idempotente e não sobrescreve chave diferente\n'
