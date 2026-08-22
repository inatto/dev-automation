#!/usr/bin/env bash
# Backend Windows/WSL do comando `chromes`.
set -euo pipefail

log(){ printf '[chromes] %s\n' "$*"; }
fail(){ printf '[chromes] ERRO: %s\n' "$*" >&2; exit 1; }

POWERSHELL='/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
[[ -f "$POWERSHELL" ]] || fail "PowerShell do Windows não encontrado: $POWERSHELL"
if ! "$POWERSHELL" -NoLogo -NoProfile -Command 'exit 0' >/dev/null 2>&1; then
  fail 'WSL Interop está desativado ou travado. No PowerShell execute: wsl --shutdown; depois reabra o Ubuntu.'
fi

case "${1:-}" in
  --help|-h|help) printf 'Uso: chromes\n'; exit 0 ;;
  "") ;;
  *) fail "opção inválida: $1" ;;
esac

PS_SCRIPT="$(mktemp --suffix=.ps1)"
cleanup(){ rm -f "$PS_SCRIPT"; }
trap cleanup EXIT

cat > "$PS_SCRIPT" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$chromeCandidates = @(
    'C:\Program Files\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
)
$chrome = $chromeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $chrome) { throw 'Google Chrome não encontrado.' }

[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
$left = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.WorkingArea.X })[0].WorkingArea
$danielProfile = if ($env:CHROMES_DANIEL_PROFILE) { $env:CHROMES_DANIEL_PROFILE } else { 'Default' }
$sindicattoProfile = if ($env:CHROMES_SINDICATTO_PROFILE) { $env:CHROMES_SINDICATTO_PROFILE } else { 'Profile 2' }

Write-Host '[chromes] Abrindo Chrome Daniel no monitor esquerdo/maximizado...'
Start-Process -FilePath $chrome -ArgumentList @(
    "--profile-directory=$danielProfile",
    '--new-window',
    "--window-position=$($left.X),$($left.Y)",
    '--start-maximized',
    'https://chatgpt.com/'
)

$urls = @()
if ($env:CHROMES_LOCAL_URLS) {
    $urls = @($env:CHROMES_LOCAL_URLS -split "`n" | Where-Object { $_.Trim() })
}
if ($env:CHROMES_SKIP_SECOND -ne '1' -and $urls.Count -gt 0) {
    Start-Sleep -Seconds 1
    Write-Host '[chromes] Abrindo Chrome Sindicatto no monitor esquerdo/maximizado...'
    $args = @(
        "--profile-directory=$sindicattoProfile",
        '--new-window',
        "--window-position=$($left.X),$($left.Y)",
        '--start-maximized'
    ) + $urls
    Start-Process -FilePath $chrome -ArgumentList $args
} else {
    Write-Host '[chromes] Chrome Sindicatto ignorado: sem URL local configurada.'
}
POWERSHELL

PS_SCRIPT_WINDOWS="$(wslpath -w "$PS_SCRIPT")"
"$POWERSHELL" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$PS_SCRIPT_WINDOWS"
log 'Concluído.'
