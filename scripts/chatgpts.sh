#!/usr/bin/env bash
# Abre uma janela do app ChatGPT do Windows para cada projeto ativo.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
CONFIG_FILE="${CHATGPTS_PROJECTS_FILE:-$PROJECT_ROOT/config/auto-code-manager.projects}"
OPEN_DELAY_SECONDS="${CHATGPTS_OPEN_DELAY_SECONDS:-1}"

log() { printf '[chatgpts] %s\n' "$*"; }
fail() { printf '[chatgpts] ERRO: %s\n' "$*" >&2; exit 1; }

show_help() {
  cat <<'HELP'
Uso:
  chatgpts          Abre uma janela do app ChatGPT para cada projeto ativo
  chatgpts --list   Mostra os projetos que receberiam uma janela
  chatgpts --help   Mostra esta ajuda

Regra:
  usa somente projetos reais de auto-code-manager.projects; agregadores *.zip não recebem janela
HELP
}

case "${1:-}" in
  --help|-h|help)
    show_help
    exit 0
    ;;
  --list|list)
    LIST_ONLY=1
    ;;
  "")
    LIST_ONLY=0
    ;;
  *)
    fail "opção inválida: $1 (use --help)"
    ;;
esac

[[ -f "$CONFIG_FILE" ]] || fail "configuração não encontrada: $CONFIG_FILE"

projects=()
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line="${raw_line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  line="${line#./}"
  line="${line%/}"
  [[ -n "$line" ]] || continue
  [[ "${line,,}" == *.zip ]] && continue
  projects+=("$(basename -- "$line")")
done < "$CONFIG_FILE"

((${#projects[@]} > 0)) || fail 'nenhum projeto ativo encontrado na configuração.'

if ((LIST_ONLY == 1)); then
  printf '%s\n' "${projects[@]}"
  exit 0
fi

POWERSHELL='/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
[[ -f "$POWERSHELL" ]] || fail "PowerShell do Windows não encontrado: $POWERSHELL"
if ! "$POWERSHELL" -NoLogo -NoProfile -Command 'exit 0' >/dev/null 2>&1; then
  fail 'WSL Interop está desativado ou travado.'
fi

ps_file="$(mktemp --suffix=.ps1)"
cleanup() { rm -f "$ps_file"; }
trap cleanup EXIT

cat > "$ps_file" <<'POWERSHELL'
param(
    [Parameter(Mandatory = $true)]
    [int]$Count,

    [Parameter(Mandatory = $true)]
    [double]$DelaySeconds
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding

$apps = @(Get-StartApps | Where-Object { $_.Name -eq 'ChatGPT' })
if ($apps.Count -eq 0) {
    $apps = @(Get-StartApps | Where-Object { $_.Name -like 'ChatGPT*' -and $_.Name -notlike '*Classic*' })
}

$app = $apps | Select-Object -First 1
if (-not $app) {
    throw 'App ChatGPT não encontrado no Windows. Instale/atualize o ChatGPT desktop app.'
}

Write-Host "[chatgpts] App: $($app.Name) [$($app.AppID)]"

for ($i = 0; $i -lt $Count; $i++) {
    Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($app.AppID)" | Out-Null
    if ($DelaySeconds -gt 0 -and $i -lt ($Count - 1)) {
        Start-Sleep -Milliseconds ([int]($DelaySeconds * 1000))
    }
}
POWERSHELL

command -v wslpath >/dev/null 2>&1 || fail 'wslpath não está disponível no WSL.'
ps_file_windows="$(wslpath -w "$ps_file")"

log "Abrindo ${#projects[@]} janela(s) do ChatGPT..."
"$POWERSHELL" \
  -NoLogo \
  -NoProfile \
  -ExecutionPolicy Bypass \
  -File "$ps_file_windows" \
  -Count "${#projects[@]}" \
  -DelaySeconds "$OPEN_DELAY_SECONDS"
log 'Concluído.'
