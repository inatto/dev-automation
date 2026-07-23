#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
CONFIG_FILE="${PHPSTORMS_PROJECTS_FILE:-$PROJECT_ROOT/config/auto-code-manager.projects}"
CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
OPEN_DELAY_SECONDS="${PHPSTORMS_OPEN_DELAY_SECONDS:-1}"
INCLUDE_DEV_AUTOMATION="${PHPSTORMS_INCLUDE_DEV_AUTOMATION:-0}"

log() { printf '[phpstorms] %s\n' "$*"; }
fail() { printf '[phpstorms] ERRO: %s\n' "$*" >&2; exit 1; }

POWERSHELL='/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
[[ -f "$POWERSHELL" ]] || fail "PowerShell do Windows não encontrado: $POWERSHELL"
if ! "$POWERSHELL" -NoLogo -NoProfile -Command 'exit 0' >/dev/null 2>&1; then
  fail 'WSL Interop está desativado ou travado. No PowerShell do Windows execute: wsl --shutdown; depois abra novamente o Ubuntu-22.04-D.'
fi
command -v python3 >/dev/null 2>&1 || fail 'python3 não está disponível no WSL.'
[[ -f "$CONFIG_FILE" ]] || fail "configuração não encontrada: $CONFIG_FILE"

projects=()
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line="${raw_line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -n "$line" ]] || continue

  project_path="$CODE_ROOT/$line"
  if [[ ! -d "$project_path" ]]; then
    log "ignorado; pasta não encontrada: $project_path"
    continue
  fi

  project_real_path="$(cd -- "$project_path" && pwd -P)"
  if [[ "$INCLUDE_DEV_AUTOMATION" != "1" && "$project_real_path" == "$PROJECT_ROOT" ]]; then
    log "ignorado no comando phpstorms: $project_path"
    continue
  fi

  projects+=("$(wslpath -w "$project_real_path")")
done < "$CONFIG_FILE"

((${#projects[@]} > 0)) || fail 'nenhum projeto válido encontrado na configuração.'

ps_file="$(mktemp --suffix=.ps1)"
json_file="$(mktemp --suffix=.json)"
cleanup() { rm -f "$ps_file" "$json_file"; }
trap cleanup EXIT

printf '%s\n' "${projects[@]}" |
  python3 -c 'import json,sys; json.dump([line.rstrip("\n") for line in sys.stdin], sys.stdout, ensure_ascii=False)' \
  > "$json_file"

cat > "$ps_file" <<'POWERSHELL'
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectsJsonFile,

    [Parameter(Mandatory = $true)]
    [double]$DelaySeconds
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding

$phpStormCandidates = @(
    Get-ChildItem 'C:\Program Files\JetBrains' -Filter 'phpstorm64.exe' -File -Recurse -ErrorAction SilentlyContinue
    Get-ChildItem "$env:LOCALAPPDATA\JetBrains\Toolbox\apps\PhpStorm" -Filter 'phpstorm64.exe' -File -Recurse -ErrorAction SilentlyContinue
) | Sort-Object LastWriteTime -Descending

$phpStorm = $phpStormCandidates | Select-Object -First 1
if (-not $phpStorm) {
    throw 'PhpStorm não encontrado em Program Files nem no JetBrains Toolbox.'
}

if (-not (Test-Path -LiteralPath $ProjectsJsonFile)) {
    throw "Arquivo temporário de projetos não encontrado: $ProjectsJsonFile"
}

$json = Get-Content -LiteralPath $ProjectsJsonFile -Raw -Encoding UTF8
if ([string]::IsNullOrWhiteSpace($json)) {
    throw 'A lista de projetos está vazia.'
}

$projects = @($json | ConvertFrom-Json)

Write-Host "[phpstorms] Executável: $($phpStorm.FullName)"

$processName = [System.IO.Path]::GetFileNameWithoutExtension($phpStorm.Name)
$phpStormWasRunning = @(Get-Process -Name $processName -ErrorAction SilentlyContinue).Count -gt 0

if (-not $phpStormWasRunning) {
    Write-Host '[phpstorms] PhpStorm está fechado; iniciando e aguardando ficar pronto...'
    Start-Process -FilePath $phpStorm.FullName | Out-Null

    $deadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Milliseconds 500
        $runningProcesses = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
    } while ($runningProcesses.Count -eq 0 -and (Get-Date) -lt $deadline)

    if ($runningProcesses.Count -eq 0) {
        throw 'O PhpStorm não iniciou dentro de 60 segundos.'
    }

    # O processo aparece antes de o mecanismo de abertura de projetos estar pronto.
    Start-Sleep -Seconds 4
}

foreach ($project in $projects) {
    Write-Host "[phpstorms] Abrindo: $project"

    # Com uma instância já inicializada, esta chamada é repassada ao PhpStorm
    # e o caminho não se perde durante a primeira inicialização.
    Start-Process -FilePath $phpStorm.FullName -ArgumentList @([string]$project) | Out-Null

    if ($DelaySeconds -gt 0) {
        Start-Sleep -Milliseconds ([int]($DelaySeconds * 1000))
    }
}
POWERSHELL

ps_file_windows="$(wslpath -w "$ps_file")"
json_file_windows="$(wslpath -w "$json_file")"

log "Abrindo ${#projects[@]} projeto(s) em janelas separadas do PhpStorm..."
"$POWERSHELL" \
  -NoLogo \
  -NoProfile \
  -ExecutionPolicy Bypass \
  -File "$ps_file_windows" \
  -ProjectsJsonFile "$json_file_windows" \
  -DelaySeconds "$OPEN_DELAY_SECONDS"
log 'Concluído.'
