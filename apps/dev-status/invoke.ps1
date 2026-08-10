[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('idle','backup','unzip','zip','sync','clean','done','error','exit')]
    [string]$State,

    [ValidateRange(-1, 100)]
    [int]$Progress = -1,

    [string]$Detail = ''
)

$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot 'bin\dev-status.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "dev-status.exe não existe. Compile primeiro: $PSScriptRoot\build.ps1"
}

$argsList = @($State)
if ($Progress -ge 0) { $argsList += [string]$Progress }
if ($Detail) { $argsList += $Detail }

& $exe @argsList
exit $LASTEXITCODE
