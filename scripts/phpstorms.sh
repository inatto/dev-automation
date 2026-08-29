#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=lib/project-config.sh
source "$PROJECT_ROOT/scripts/lib/project-config.sh"
CONFIG_FILE="${PHPSTORMS_PROJECTS_FILE:-$(dev_projects_file "$PROJECT_ROOT")}"
CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
OPEN_DELAY_SECONDS="${PHPSTORMS_OPEN_DELAY_SECONDS:-5}"

log() { printf '[phpstorms] %s\n' "$*"; }
fail() { printf '[phpstorms] ERRO: %s\n' "$*" >&2; exit 1; }

show_help() {
  cat <<'EOF_HELP'
Uso:
  phpstorms          Abre os projetos configurados no PhpStorm
  phpstorms --list   Mostra as pastas que seriam abertas, sem iniciar o PhpStorm
  phpstorms --help   Mostra esta ajuda

Regra:
  abre somente projetos reais do arquivo `.projects` da máquina; agregadores *.zip não abrem IDE
EOF_HELP
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
[[ -d "$CODE_ROOT" ]] || fail "raiz de projetos não encontrada: $CODE_ROOT"

# Usa exatamente a mesma fonte canônica e a mesma ordem do comando desktops.
# Agregadores *.zip são indicadores de backup/importação, nunca projetos de IDE.
# Não agrupa projetos irmãos e não ignora dev-automation. Se uma pasta ativa
# não existir, falha para evitar que phpstorms fique diferente de desktops.
resolved_projects=()
declare -A seen_projects=()
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line="${raw_line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  line="${line#./}"
  line="${line%/}"
  [[ -n "$line" ]] || continue
  [[ "${line,,}" == *.zip ]] && continue

  project_path="$CODE_ROOT/$line"
  [[ -d "$project_path" ]] || fail "projeto ativo não encontrado: $project_path"

  project_real_path="$(cd -- "$project_path" && pwd -P)"
  if [[ -z "${seen_projects["$project_real_path"]:-}" ]]; then
    seen_projects["$project_real_path"]=1
    resolved_projects+=("$project_real_path")
  fi
done < "$CONFIG_FILE"

((${#resolved_projects[@]} > 0)) || fail 'nenhum projeto ativo encontrado na configuração.'

if ((LIST_ONLY == 1)); then
  printf '%s\n' "${resolved_projects[@]}"
  exit 0
fi

POWERSHELL='/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
[[ -f "$POWERSHELL" ]] || fail "PowerShell do Windows não encontrado: $POWERSHELL"
if ! "$POWERSHELL" -NoLogo -NoProfile -Command 'exit 0' >/dev/null 2>&1; then
  fail 'WSL Interop está desativado ou travado. No PowerShell do Windows execute: wsl --shutdown; depois abra novamente o Ubuntu-22.04-D.'
fi
command -v python3 >/dev/null 2>&1 || fail 'python3 não está disponível no WSL.'
command -v wslpath >/dev/null 2>&1 || fail 'wslpath não está disponível no WSL.'

windows_projects=()
for project in "${resolved_projects[@]}"; do
  windows_projects+=("$(wslpath -w "$project")")
done

ps_file="$(mktemp --suffix=.ps1)"
json_file="$(mktemp --suffix=.json)"
cleanup() { rm -f "$ps_file" "$json_file"; }
trap cleanup EXIT

printf '%s\n' "${windows_projects[@]}" |
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

$parsedProjects = ConvertFrom-Json -InputObject $json
$projects = @(
    foreach ($project in $parsedProjects) {
        [string]$project
    }
)

Write-Host "[phpstorms] Executável: $($phpStorm.FullName)"

$processName = [System.IO.Path]::GetFileNameWithoutExtension($phpStorm.Name)

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class PhpStormWindowEnumerator
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);
}
'@

function Get-PhpStormWindowTitles {
    $processIds = @(
        Get-Process -Name $processName -ErrorAction SilentlyContinue |
            ForEach-Object { [uint32]$_.Id }
    )

    if ($processIds.Count -eq 0) {
        return @()
    }

    $titles = [System.Collections.Generic.List[string]]::new()
    $callback = [PhpStormWindowEnumerator+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)

        if (-not [PhpStormWindowEnumerator]::IsWindowVisible($hWnd)) {
            return $true
        }

        [uint32]$windowProcessId = 0
        [void][PhpStormWindowEnumerator]::GetWindowThreadProcessId($hWnd, [ref]$windowProcessId)
        if ($processIds -notcontains $windowProcessId) {
            return $true
        }

        $length = [PhpStormWindowEnumerator]::GetWindowTextLength($hWnd)
        if ($length -le 0) {
            return $true
        }

        $buffer = [System.Text.StringBuilder]::new($length + 1)
        [void][PhpStormWindowEnumerator]::GetWindowText($hWnd, $buffer, $buffer.Capacity)
        $title = $buffer.ToString().Trim()
        if (-not [string]::IsNullOrWhiteSpace($title)) {
            [void]$titles.Add($title)
        }

        return $true
    }

    [void][PhpStormWindowEnumerator]::EnumWindows($callback, [IntPtr]::Zero)
    return @($titles)
}

function Get-ProjectWindowNames {
    param([Parameter(Mandatory = $true)][string]$Project)

    $names = [System.Collections.Generic.List[string]]::new()
    $leaf = Split-Path -Leaf $Project.TrimEnd('\')
    if (-not [string]::IsNullOrWhiteSpace($leaf)) {
        [void]$names.Add($leaf.Trim())
    }

    $ideaNameFile = Join-Path $Project '.idea\.name'
    if (Test-Path -LiteralPath $ideaNameFile) {
        $ideaName = Get-Content -LiteralPath $ideaNameFile -Raw -ErrorAction SilentlyContinue
        if ($null -ne $ideaName) {
            $ideaName = $ideaName.Trim()
            if (-not [string]::IsNullOrWhiteSpace($ideaName) -and $names -notcontains $ideaName) {
                [void]$names.Add($ideaName)
            }
        }
    }

    return @($names)
}

function Test-ProjectOpen {
    param([Parameter(Mandatory = $true)][string]$Project)

    $titles = @(Get-PhpStormWindowTitles)
    if ($titles.Count -eq 0) {
        return $false
    }

    foreach ($name in @(Get-ProjectWindowNames -Project $Project)) {
        foreach ($title in $titles) {
            if ($title.IndexOf($name, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $true
            }
        }
    }

    return $false
}

function Wait-ProjectWindow {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-ProjectOpen -Project $Project) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return $false
}

$phpStormWasRunning = @(Get-Process -Name $processName -ErrorAction SilentlyContinue).Count -gt 0

if (-not $phpStormWasRunning) {
    $firstProject = [string]$projects[0]
    Write-Host "[phpstorms] PhpStorm está fechado; abrindo diretamente: $firstProject"

    # Evita que o PhpStorm restaure automaticamente a sessão anterior e depois
    # receba a mesma lista novamente pelo script.
    Start-Process -FilePath $phpStorm.FullName -ArgumentList @('dontReopenProjects', $firstProject) | Out-Null

    $deadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Milliseconds 500
        $runningProcesses = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
    } while ($runningProcesses.Count -eq 0 -and (Get-Date) -lt $deadline)

    if ($runningProcesses.Count -eq 0) {
        throw 'O PhpStorm não iniciou dentro de 60 segundos.'
    }

    if (-not (Wait-ProjectWindow -Project $firstProject -TimeoutSeconds 60)) {
        throw "O PhpStorm iniciou, mas a janela do primeiro projeto não apareceu: $firstProject"
    }

    if ($DelaySeconds -gt 0) {
        Start-Sleep -Milliseconds ([int]($DelaySeconds * 1000))
    }
}

foreach ($project in $projects) {
    $project = [string]$project

    if (Test-ProjectOpen -Project $project) {
        Write-Host "[phpstorms] Já aberto; ignorando: $project"
        continue
    }

    Write-Host "[phpstorms] Abrindo: $project"
    Start-Process -FilePath $phpStorm.FullName -ArgumentList @($project) | Out-Null

    if ($DelaySeconds -gt 0) {
        Start-Sleep -Milliseconds ([int]($DelaySeconds * 1000))
    }
}
POWERSHELL

ps_file_windows="$(wslpath -w "$ps_file")"
json_file_windows="$(wslpath -w "$json_file")"

log "Abrindo ${#windows_projects[@]} projeto(s) em janelas separadas do PhpStorm..."
"$POWERSHELL" \
  -NoLogo \
  -NoProfile \
  -ExecutionPolicy Bypass \
  -File "$ps_file_windows" \
  -ProjectsJsonFile "$json_file_windows" \
  -DelaySeconds "$OPEN_DELAY_SECONDS"
log 'Concluído.'
