#!/usr/bin/env bash
# Backend Windows/WSL do comando `files`.
set -euo pipefail

log(){ printf '[files] %s\n' "$*"; }
fail(){ printf '[files] ERRO: %s\n' "$*" >&2; exit 1; }

POWERSHELL='/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
[[ -f "$POWERSHELL" ]] || fail "PowerShell do Windows não encontrado: $POWERSHELL"

case "${1:-}" in
  --help|-h|help) printf 'Uso: files\n'; exit 0 ;;
  "") ;;
  *) fail "opção inválida: $1" ;;
esac

wsl_path="${FILES_DIR:-/home/daniel/Code}"
windows_path="$(wslpath -w "$wsl_path")"
FILES_WINDOWS_PATH="$windows_path" "$POWERSHELL" -NoLogo -NoProfile -Command '
$ErrorActionPreference = "Stop"
[void][System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
$left = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.WorkingArea.X })[0].WorkingArea
Start-Process -FilePath "explorer.exe" -ArgumentList $env:FILES_WINDOWS_PATH | Out-Null
Start-Sleep -Milliseconds 700
$shell = New-Object -ComObject Shell.Application
$window = $shell.Windows() | Where-Object { $_.FullName -and ([System.IO.Path]::GetFileName($_.FullName) -ieq "explorer.exe") } | Select-Object -Last 1
if (-not $window) { throw "A janela do Explorer não foi encontrada." }
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class FilesWindowPlacement {
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int X, int Y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int cmd);
}
"@
[FilesWindowPlacement]::SetWindowPos([IntPtr]([int64]$window.HWND), [IntPtr]::Zero, $left.X, $left.Y, $left.Width, $left.Height, 0x0040) | Out-Null
[FilesWindowPlacement]::ShowWindowAsync([IntPtr]([int64]$window.HWND), 3) | Out-Null
' >/dev/null
log 'Concluído.'
