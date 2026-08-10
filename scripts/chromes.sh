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

PS_SCRIPT="$(mktemp --suffix=.ps1)"
cleanup() { rm -f "$PS_SCRIPT"; }
trap cleanup EXIT

cat > "$PS_SCRIPT" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'

$chromeCandidates = @(
    'C:\Program Files\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
)
$chrome = $chromeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $chrome) { throw 'Google Chrome não encontrado.' }

[void][System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$leftWidth = [Math]::Floor($area.Width / 2)
$screens = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.WorkingArea.X })
if ($screens.Count -lt 3) { throw 'São necessários 3 monitores para identificar esquerda, centro e direita.' }
$centralScreen = $screens[[Math]::Floor($screens.Count / 2)]

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WindowPlacement {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(
        IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
}
'@

Write-Host '[chromes] Abrindo Chrome Daniel...'
Start-Process -FilePath $chrome -ArgumentList @(
    '--profile-directory="Default"',
    '--new-window',
    'https://chatgpt.com/'
)

Write-Host '[chromes] Abrindo Chrome Sindicatto na metade esquerda...'
Start-Process -FilePath $chrome -ArgumentList @(
    '--profile-directory="Profile 2"',
    '--new-window',
    "--window-position=$($area.X),$($area.Y)",
    "--window-size=$leftWidth,$($area.Height)",
    'chrome://newtab/'
)

Write-Host "[chromes] Abrindo Explorer no monitor central: $($centralScreen.DeviceName)..."
$shell = New-Object -ComObject Shell.Application
$beforeExplorerWindows = @(
    $shell.Windows() |
        Where-Object { $_.FullName -and ([System.IO.Path]::GetFileName($_.FullName) -ieq 'explorer.exe') } |
        ForEach-Object { [int64]$_.HWND }
)
Start-Process -FilePath 'explorer.exe' | Out-Null

$explorerWindow = $null
$deadline = (Get-Date).AddSeconds(10)
do {
    Start-Sleep -Milliseconds 200
    $explorerWindow = $shell.Windows() |
        Where-Object {
            $_.FullName -and
            ([System.IO.Path]::GetFileName($_.FullName) -ieq 'explorer.exe') -and
            ($beforeExplorerWindows -notcontains [int64]$_.HWND)
        } |
        Select-Object -First 1
} while (-not $explorerWindow -and (Get-Date) -lt $deadline)

if (-not $explorerWindow) {
    throw 'A nova janela do Explorer não foi encontrada.'
}

$centralArea = $centralScreen.WorkingArea
$placed = [WindowPlacement]::SetWindowPos(
    [IntPtr]([int64]$explorerWindow.HWND),
    [IntPtr]::Zero,
    $centralArea.X,
    $centralArea.Y,
    $centralArea.Width,
    $centralArea.Height,
    0x0040
)
if (-not $placed) { throw 'Não foi possível posicionar o Explorer no monitor central.' }

POWERSHELL

PS_SCRIPT_WINDOWS="$(wslpath -w "$PS_SCRIPT")"
"$POWERSHELL" -NoLogo -NoProfile -ExecutionPolicy Bypass \
  -File "$PS_SCRIPT_WINDOWS"

log 'Concluído.'
