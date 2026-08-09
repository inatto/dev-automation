#!/usr/bin/env bash
# Sincroniza desktops virtuais do Windows com os projetos ativos.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PROJECTS_FILE="${PROJECTS_FILE:-$PROJECT_ROOT/config/auto-code-manager.projects}"

log() { printf '[desktops] %s\n' "$*"; }
fail() { printf '[desktops] ERRO: %s\n' "$*" >&2; exit 1; }

[[ -f "$PROJECTS_FILE" ]] || fail "arquivo de projetos não encontrado: $PROJECTS_FILE"

projects=()
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line="${raw_line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  line="${line#./}"
  line="${line%/}"
  [[ -n "$line" ]] || continue
  projects+=("$(basename -- "$line")")
done < "$PROJECTS_FILE"

((${#projects[@]} > 0)) || fail "nenhum projeto ativo configurado"

show_list() {
  printf '1\tLAZER (preservado)\n'
  local index=2 project
  for project in "${projects[@]}"; do
    printf '%d\t%s\n' "$index" "$project"
    ((index += 1))
  done
}

case "${1:-}" in
  --list|list)
    show_list
    exit 0
    ;;
  --help|-h|help)
    cat <<'HELP'
Uso:
  desktops --list   Mostra Desktop 1 + projetos, sem alterar o Windows
  desktops          Cria os desktops que faltam e nomeia Desktop 2+ pela ordem dos projetos ativos

O Desktop 1 é preservado. Desktops extras existentes não são removidos.
HELP
    exit 0
    ;;
  "")
    ;;
  *)
    fail "argumento inválido: $1 (use --help)"
    ;;
esac

command -v powershell.exe >/dev/null 2>&1 || fail "powershell.exe não encontrado; execute dentro do WSL no Windows"
command -v iconv >/dev/null 2>&1 || fail "iconv não encontrado"
command -v base64 >/dev/null 2>&1 || fail "base64 não encontrado"

sync_script="$({
  printf '$projects = @(\n'
  for project in "${projects[@]}"; do
    escaped="${project//\'/\'\'}"
    printf "    '%s'\n" "$escaped"
  done
  cat <<'POWERSHELL_SYNC'
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
Import-Module VirtualDesktop -DisableNameChecking

$requiredCount = 1 + $projects.Count
while ((Get-DesktopCount) -lt $requiredCount) {
    New-Desktop | Out-Null
}
for ($i = 0; $i -lt $projects.Count; $i++) {
    $desktop = Get-Desktop ($i + 1)
    Set-DesktopName -Desktop $desktop -Name ([string]$projects[$i])
}
Write-Host ("[desktops] Desktop 1 preservado; {0} desktop(s) de projeto sincronizado(s)." -f $projects.Count)
POWERSHELL_SYNC
})"

encoded_command="$(printf '%s' "$sync_script" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand "$encoded_command"
