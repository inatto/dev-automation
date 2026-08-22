#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d /tmp/desktops-test-XXXXXX)"
trap 'rm -rf -- "$TEMP_ROOT"' EXIT

PROJECTS_FILE="$TEMP_ROOT/projects"
cat > "$PROJECTS_FILE" <<'PROJECTS'
#orgs/disabled
bots/dev-automation
infra/amazon-infra
orgs/orbital.zip
orgs/orbital/orbital-app
PROJECTS

output="$(PROJECTS_FILE="$PROJECTS_FILE" "$PROJECT_ROOT/scripts/desktops.sh" --list)"
expected=$'1\tLAZER (preservado)\n2\tdev-automation\n3\tamazon-infra\n4\torbital-app\n5\tlrdp1\n6\tlrdp2'

[[ "$output" == "$expected" ]] || {
  printf 'FALHOU: ordem de desktops inesperada\nEsperado:\n%s\nRecebido:\n%s\n' "$expected" "$output" >&2
  exit 1
}

printf 'OK: Desktop 1 preservado; agregadores *.zip não viram desktops; projetos reais mantêm a ordem\n'

FAKE_BIN="$TEMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/powershell.exe" <<'FAKEPS'
#!/usr/bin/env bash
set -euo pipefail
encoded=''
while (($#)); do
  if [[ "$1" == '-EncodedCommand' ]]; then
    shift
    encoded="${1:-}"
    break
  fi
  shift
done
[[ -n "$encoded" ]] || { printf 'FALHOU: -EncodedCommand ausente\n' >&2; exit 97; }
decoded="$(printf '%s' "$encoded" | base64 -d | iconv -f UTF-16LE -t UTF-8)"
grep -q 'New-Desktop' <<<"$decoded" || { printf 'FALHOU: New-Desktop ausente\n' >&2; exit 96; }
grep -q 'Set-DesktopName' <<<"$decoded" || { printf 'FALHOU: Set-DesktopName ausente\n' >&2; exit 95; }
grep -q "'dev-automation'" <<<"$decoded" || { printf 'FALHOU: dev-automation ausente\n' >&2; exit 94; }
grep -q "'amazon-infra'" <<<"$decoded" || { printf 'FALHOU: amazon-infra ausente\n' >&2; exit 93; }
grep -q "'orbital-app'" <<<"$decoded" || { printf 'FALHOU: orbital-app ausente\n' >&2; exit 92; }
grep -q "'lrdp1'" <<<"$decoded" || { printf 'FALHOU: lrdp1 ausente\n' >&2; exit 91; }
grep -q "'lrdp2'" <<<"$decoded" || { printf 'FALHOU: lrdp2 ausente\n' >&2; exit 90; }
printf '[desktops] fake sync ok\n'
FAKEPS
cat > "$FAKE_BIN/wslpath" <<'FAKEWSL'
#!/usr/bin/env bash
printf 'FALHOU: desktops simples chamou wslpath\n' >&2
exit 99
FAKEWSL
chmod +x "$FAKE_BIN/powershell.exe" "$FAKE_BIN/wslpath"

for _ in 1 2 3; do
  PATH="$FAKE_BIN:$PATH" DESKTOPS_PLATFORM=windows PROJECTS_FILE="$PROJECTS_FILE" "$PROJECT_ROOT/scripts/desktops.sh" >/dev/null
done

printf 'OK: desktops simples roda repetidamente sem wslpath nem temporários Windows\n'

if PATH="$FAKE_BIN:$PATH" DESKTOPS_PLATFORM=windows PROJECTS_FILE="$PROJECTS_FILE" "$PROJECT_ROOT/scripts/desktops.sh" --apps >/dev/null 2>&1; then
  printf 'FALHOU: --apps ainda foi aceito\n' >&2
  exit 1
fi
printf 'OK: --apps removido; desktops aceita somente sincronização/listagem\n'
