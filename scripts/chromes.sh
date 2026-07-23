#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation

set -euo pipefail

log() { printf '[chromes] %s\n' "$*"; }
fail() { printf '[chromes] ERRO: %s\n' "$*" >&2; exit 1; }

POWERSHELL='/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
[[ -f "$POWERSHELL" ]] || fail "PowerShell do Windows não encontrado: $POWERSHELL"

# Valida o WSL Interop antes de esconder qualquer saída em background.
if ! "$POWERSHELL" -NoLogo -NoProfile -Command 'exit 0' >/dev/null 2>&1; then
  fail 'WSL Interop está desativado ou travado. No PowerShell do Windows execute: wsl --shutdown; depois abra novamente o Ubuntu-22.04-D.'
fi

CODE_DIR='/home/daniel/Code'
[[ -d "$CODE_DIR" ]] || fail "pasta não encontrada: $CODE_DIR"
CODE_WINDOWS="$(wslpath -w "$CODE_DIR")"

PS_SCRIPT="$(mktemp --suffix=.ps1)"
cleanup() { rm -f "$PS_SCRIPT"; }
trap cleanup EXIT

cat > "$PS_SCRIPT" <<'POWERSHELL'
param([Parameter(Mandatory=$true)][string]$CodeDirectory)
$ErrorActionPreference = 'Stop'

$chromeCandidates = @(
    'C:\Program Files\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
)
$chrome = $chromeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $chrome) { throw 'Google Chrome não encontrado.' }

Write-Host '[chromes] Abrindo o perfil Default somente no ChatGPT...'
Start-Process -FilePath $chrome -ArgumentList @(
    '--profile-directory=Default',
    '--new-window',
    '--start-maximized',
    'https://chatgpt.com/'
)

Start-Sleep -Seconds 1

Write-Host '[chromes] Abrindo o Profile 2 em uma nova aba vazia...'
Start-Process -FilePath $chrome -ArgumentList @(
    '--profile-directory="Profile 2"',
    '--new-window',
    '--start-maximized',
    'chrome://newtab/'
)

Start-Sleep -Seconds 1

Write-Host '[chromes] Abrindo a pasta Code no Explorer...'
Start-Process -FilePath 'explorer.exe' -ArgumentList @($CodeDirectory)
POWERSHELL

PS_SCRIPT_WINDOWS="$(wslpath -w "$PS_SCRIPT")"
"$POWERSHELL" -NoLogo -NoProfile -ExecutionPolicy Bypass \
  -File "$PS_SCRIPT_WINDOWS" \
  -CodeDirectory "$CODE_WINDOWS"

log 'Concluído.'
