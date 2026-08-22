#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
CONFIG_FILE="${PYCHARMS_PROJECTS_FILE:-$PROJECT_ROOT/config/auto-code-manager.projects}"
CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
OPEN_DELAY_SECONDS="${PYCHARMS_OPEN_DELAY_SECONDS:-5}"

log() { printf '[pycharms] %s\n' "$*"; }
warn() { printf '[pycharms] AVISO: %s\n' "$*" >&2; }
fail() { printf '[pycharms] ERRO: %s\n' "$*" >&2; exit 1; }

show_help() {
  cat <<'EOF_HELP'
Uso:
  pycharms          Abre os projetos configurados no PyCharm
  pycharms --list   Mostra as pastas que seriam abertas, sem iniciar o PyCharm
  pycharms --help   Mostra esta ajuda

Regra:
  abre os projetos-raiz ativos de auto-code-manager.projects; ignora agregadores *.zip e subprojetos apps/ quando o pai também está ativo
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

# Usa a fonte canônica de projetos, mas a IDE trabalha somente com o
# grid efetivo: entradas cadastradas cuja pasta existe de verdade.
configured_projects=()
effective_projects=()
declare -A configured_set=()
declare -A effective_set=()
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  raw_line="${raw_line%$'\r'}"
  line="${raw_line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  line="${line#./}"
  line="${line%/}"
  [[ -n "$line" ]] || continue
  [[ "${line,,}" == *.zip ]] && continue

  if [[ -z "${configured_set["$line"]:-}" ]]; then
    configured_set["$line"]=1
    configured_projects+=("$line")
  fi
done < "$CONFIG_FILE"

# Só existe no grid se a pasta existe. Projeto ausente nunca derruba `pycharms`.
for line in "${configured_projects[@]}"; do
  project_path="$CODE_ROOT/$line"
  if [[ ! -d "$project_path" ]]; then
    warn "fora do grid; projeto ainda ausente: $project_path"
    continue
  fi
  effective_set["$line"]=1
  effective_projects+=("$line")
done

resolved_projects=()
declare -A seen_projects=()
for line in "${effective_projects[@]}"; do
  # Um pai só cobre apps/<filho> se o próprio pai também existe e está no
  # grid efetivo. Cadastro morto não pode esconder projeto existente.
  candidate="$line"
  skip_nested_app=0
  while [[ "$candidate" == */apps/* ]]; do
    parent="${candidate%/apps/*}"
    if [[ -n "${effective_set["$parent"]:-}" ]]; then
      skip_nested_app=1
      break
    fi
    candidate="$parent"
  done
  ((skip_nested_app == 1)) && continue

  project_path="$CODE_ROOT/$line"
  project_real_path="$(cd -- "$project_path" && pwd -P)"
  if [[ -z "${seen_projects["$project_real_path"]:-}" ]]; then
    seen_projects["$project_real_path"]=1
    resolved_projects+=("$project_real_path")
  fi
done

((${#resolved_projects[@]} > 0)) || fail 'nenhum projeto existente no grid efetivo.'

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

$preferredPyCharm = 'C:\Program Files\JetBrains\PyCharm 2026.2.1\bin\pycharm64.exe'
if (Test-Path -LiteralPath $preferredPyCharm) {
    $pyCharm = Get-Item -LiteralPath $preferredPyCharm
} else {
    $pyCharmCandidates = @(
        Get-ChildItem 'C:\Program Files\JetBrains' -Filter 'pycharm64.exe' -File -Recurse -ErrorAction SilentlyContinue
        Get-ChildItem "$env:LOCALAPPDATA\JetBrains\Toolbox\apps\PyCharm" -Filter 'pycharm64.exe' -File -Recurse -ErrorAction SilentlyContinue
    ) | Sort-Object LastWriteTime -Descending
    $pyCharm = $pyCharmCandidates | Select-Object -First 1
}
if (-not $pyCharm) {
    throw 'PyCharm não encontrado em Program Files nem no JetBrains Toolbox.'
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

Write-Host "[pycharms] Executável: $($pyCharm.FullName)"

$processName = [System.IO.Path]::GetFileNameWithoutExtension($pyCharm.Name)

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class PyCharmWindowEnumerator
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

function Get-PyCharmWindowTitles {
    $processIds = @(
        Get-Process -Name $processName -ErrorAction SilentlyContinue |
            ForEach-Object { [uint32]$_.Id }
    )

    if ($processIds.Count -eq 0) {
        return @()
    }

    $titles = [System.Collections.Generic.List[string]]::new()
    $callback = [PyCharmWindowEnumerator+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)

        if (-not [PyCharmWindowEnumerator]::IsWindowVisible($hWnd)) {
            return $true
        }

        [uint32]$windowProcessId = 0
        [void][PyCharmWindowEnumerator]::GetWindowThreadProcessId($hWnd, [ref]$windowProcessId)
        if ($processIds -notcontains $windowProcessId) {
            return $true
        }

        $length = [PyCharmWindowEnumerator]::GetWindowTextLength($hWnd)
        if ($length -le 0) {
            return $true
        }

        $buffer = [System.Text.StringBuilder]::new($length + 1)
        [void][PyCharmWindowEnumerator]::GetWindowText($hWnd, $buffer, $buffer.Capacity)
        $title = $buffer.ToString().Trim()
        if (-not [string]::IsNullOrWhiteSpace($title)) {
            [void]$titles.Add($title)
        }

        return $true
    }

    [void][PyCharmWindowEnumerator]::EnumWindows($callback, [IntPtr]::Zero)
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

    $titles = @(Get-PyCharmWindowTitles)
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

$pyCharmWasRunning = @(Get-Process -Name $processName -ErrorAction SilentlyContinue).Count -gt 0

if (-not $pyCharmWasRunning) {
    $firstProject = [string]$projects[0]
    Write-Host "[pycharms] PyCharm está fechado; abrindo diretamente: $firstProject"

    # Evita que o PyCharm restaure automaticamente a sessão anterior e depois
    # receba a mesma lista novamente pelo script.
    Start-Process -FilePath $pyCharm.FullName -ArgumentList @('dontReopenProjects', $firstProject) | Out-Null

    $deadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Milliseconds 500
        $runningProcesses = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
    } while ($runningProcesses.Count -eq 0 -and (Get-Date) -lt $deadline)

    if ($runningProcesses.Count -eq 0) {
        throw 'O PyCharm não iniciou dentro de 60 segundos.'
    }

    if (-not (Wait-ProjectWindow -Project $firstProject -TimeoutSeconds 60)) {
        throw "O PyCharm iniciou, mas a janela do primeiro projeto não apareceu: $firstProject"
    }

    if ($DelaySeconds -gt 0) {
        Start-Sleep -Milliseconds ([int]($DelaySeconds * 1000))
    }
}

foreach ($project in $projects) {
    $project = [string]$project

    if (Test-ProjectOpen -Project $project) {
        Write-Host "[pycharms] Já aberto; ignorando: $project"
        continue
    }

    Write-Host "[pycharms] Abrindo: $project"
    Start-Process -FilePath $pyCharm.FullName -ArgumentList @($project) | Out-Null

    if ($DelaySeconds -gt 0) {
        Start-Sleep -Milliseconds ([int]($DelaySeconds * 1000))
    }
}
POWERSHELL

ps_file_windows="$(wslpath -w "$ps_file")"
json_file_windows="$(wslpath -w "$json_file")"

log "Abrindo ${#windows_projects[@]} projeto(s) em janelas separadas do PyCharm..."
"$POWERSHELL" \
  -NoLogo \
  -NoProfile \
  -ExecutionPolicy Bypass \
  -File "$ps_file_windows" \
  -ProjectsJsonFile "$json_file_windows" \
  -DelaySeconds "$OPEN_DELAY_SECONDS"
log 'Concluído.'
