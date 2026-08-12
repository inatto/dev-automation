#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d /tmp/auto-code-parent-generic-test-XXXXXX)"
TEST_PROJECT="$TEMP_ROOT/dev-automation"
CODE_ROOT="$TEMP_ROOT/Code"
MANAGER="$TEST_PROJECT/scripts/auto-code-manager.sh"
FAKE_BIN="$TEMP_ROOT/fake-bin"

cleanup() {
  rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT

cp -a -- "$PROJECT_ROOT" "$TEST_PROJECT"
mkdir -p "$FAKE_BIN" \
  "$CODE_ROOT/orgs/acme/platform/api" \
  "$CODE_ROOT/orgs/acme/platform/web" \
  "$CODE_ROOT/orgs/acme/worker"

cat > "$FAKE_BIN/powershell.exe" <<'PS'
#!/usr/bin/env bash
exit 0
PS
chmod +x "$FAKE_BIN/powershell.exe"

printf 'api\n' > "$CODE_ROOT/orgs/acme/platform/api/app.txt"
printf 'web\n' > "$CODE_ROOT/orgs/acme/platform/web/app.txt"
printf 'worker\n' > "$CODE_ROOT/orgs/acme/worker/app.txt"
printf 'nao incluir\n' > "$CODE_ROOT/orgs/acme/platform/README-platform.txt"
printf 'nao incluir\n' > "$CODE_ROOT/orgs/acme/README-acme.txt"

cat > "$TEST_PROJECT/config/auto-code-manager.projects" <<'PROJECTS'
orgs/acme/platform.zip
orgs/acme.zip
Code.zip
orgs/acme/platform/api
orgs/acme/platform/web
orgs/acme/worker
PROJECTS

cat > "$TEST_PROJECT/config/auto-code-manager.ignore-zip" <<'SAFE_IGNORE'
.git/
.venv/
venv/
node_modules/
SAFE_IGNORE
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"

PATH="$FAKE_BIN:$PATH" CODE_ROOT="$CODE_ROOT" "$MANAGER" --backup-once >/dev/null

for archive in api.zip web.zip worker.zip platform.zip acme.zip Code.zip; do
  [ -s "$CODE_ROOT/$archive" ] || {
    printf 'FALHOU: ZIP ausente: %s\n' "$archive" >&2
    exit 1
  }
  unzip -tq "$CODE_ROOT/$archive" >/dev/null
done

platform_entries="$(unzip -Z1 "$CODE_ROOT/platform.zip" | sort)"
[ "$platform_entries" = $'api.zip\nweb.zip' ] || {
  printf 'FALHOU: platform.zip não contém exclusivamente os filhos imediatos ativos:\n%s\n' "$platform_entries" >&2
  exit 1
}

acme_entries="$(unzip -Z1 "$CODE_ROOT/acme.zip" | sort)"
[ "$acme_entries" = $'platform.zip\nworker.zip' ] || {
  printf 'FALHOU: acme.zip não contém exclusivamente os filhos imediatos ativos:\n%s\n' "$acme_entries" >&2
  exit 1
}

code_entries="$(unzip -Z1 "$CODE_ROOT/Code.zip" | sort)"
[ "$code_entries" = 'acme.zip' ] || { printf 'FALHOU: Code.zip duplicou ramo acme: %s\n' "$code_entries" >&2; exit 1; }
printf 'OK: agregadores explícitos funcionam em qualquer profundidade e não duplicam ramos\n'
