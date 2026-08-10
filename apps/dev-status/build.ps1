[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$src = Join-Path $root 'src\main.cpp'
$bin = Join-Path $root 'bin'
$build = Join-Path $root 'build'
$exe = Join-Path $bin 'dev-status.exe'

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'Visual Studio Build Tools não encontrado (vswhere.exe ausente). Instale o workload C++ Desktop.'
}

$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) {
    throw 'MSVC C++ Build Tools não encontrado. Instale o workload C++ Desktop.'
}

$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars)) {
    throw "vcvars64.bat não encontrado: $vcvars"
}

New-Item -ItemType Directory -Force -Path $bin, $build | Out-Null

# O executável fica residente no system tray. Ao recompilar uma versão nova,
# encerra somente a instância carregada a partir deste mesmo caminho para que
# o linker possa substituir o binário sem deixar a versão antiga em memória.
if (Test-Path -LiteralPath $exe) {
    try {
        & $exe exit *> $null
    } catch {
        # A versão antiga pode não responder; a checagem de processo abaixo resolve.
    }
    Start-Sleep -Milliseconds 250

    $targetExe = [System.IO.Path]::GetFullPath($exe)
    Get-Process -Name 'dev-status' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $processExe = [System.IO.Path]::GetFullPath($_.Path)
            if ([string]::Equals($processExe, $targetExe, [System.StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process -Id $_.Id -Force -ErrorAction Stop
                $_.WaitForExit(2000) | Out-Null
            }
        } catch {
            # Processo já saiu ou não foi possível consultar o caminho; o build
            # continuará e o linker será a validação final de que o arquivo está livre.
        }
    }
}

# pushd aceita caminho UNC (\\wsl.localhost\...) e cria um drive temporário,
# evitando a limitação do cmd.exe com diretório atual UNC.
$command = @"
call "$vcvars" >nul &&
pushd "$root" &&
cl.exe /nologo /std:c++20 /O2 /EHsc /W4 /permissive- /utf-8 /MT /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX /Fo"build\\" /Fe"bin\\dev-status.exe" "src\\main.cpp" /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib advapi32.lib gdi32.lib &&
popd
"@ -replace "`r?`n", ' '

& cmd.exe /d /s /c $command
if ($LASTEXITCODE -ne 0) {
    throw "Falha ao compilar dev-status (cl.exe exit $LASTEXITCODE)."
}

if (-not (Test-Path -LiteralPath $exe)) {
    throw "Build terminou sem gerar: $exe"
}

Write-Host "OK: $exe"
