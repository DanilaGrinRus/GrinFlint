# Тесты чистой логики GrinFlintCore под Windows — без macOS и Xcode.
#
# Требования:
#   winget install --id Swift.Toolchain -e
#   Visual Studio 2022 Build Tools с компонентом C++ (MSVC + Windows SDK)
#
# Запуск из корня репозитория:
#   pwsh -File scripts/swift-test.ps1
#   pwsh -File scripts/swift-test.ps1 -Filter PendingOperationsStoreTests
param(
    [string]$Filter
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

$swiftRoot = Join-Path $env:LOCALAPPDATA 'Programs\Swift'
if (-not (Test-Path $swiftRoot)) {
    throw 'Swift for Windows не найден: winget install --id Swift.Toolchain -e'
}

$toolchain = Get-ChildItem (Join-Path $swiftRoot 'Toolchains') -Directory |
    Sort-Object Name -Descending | Select-Object -First 1
$runtime = Get-ChildItem (Join-Path $swiftRoot 'Runtimes') -Directory |
    Sort-Object Name -Descending | Select-Object -First 1
$swiftBin = Join-Path $toolchain.FullName 'usr\bin'
$runtimeBin = Join-Path $runtime.FullName 'usr\bin'

# SDK-путь установщик пишет в пользовательский SDKROOT; в старых сессиях его нет.
if (-not $env:SDKROOT) {
    $platform = Get-ChildItem (Join-Path $swiftRoot 'Platforms') -Directory |
        Sort-Object Name -Descending | Select-Object -First 1
    $env:SDKROOT = Join-Path $platform.FullName 'Windows.platform\Developer\SDKs\Windows.sdk'
}

# MSVC-окружение: без link.exe/cl.exe SwiftPM не слинкует тестовый бандл.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    $vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
    if (Test-Path $vcvars) {
        cmd /c "`"$vcvars`" >nul 2>&1 && set" | ForEach-Object {
            if ($_ -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
                Set-Item -Path ("env:" + $matches[1]) -Value $matches[2]
            }
        }
    }
}

$env:Path = "$swiftBin;$runtimeBin;$env:Path"

# Короткий TMP внутри репозитория: длинные пути ломают линковку MSVC,
# а песочницы сессий могут запрещать запись во внешние каталоги.
$shortTmp = Join-Path $repo '.build\tmp'
New-Item -ItemType Directory -Force $shortTmp | Out-Null
$env:TMP = $shortTmp
$env:TEMP = $shortTmp

Push-Location $repo
try {
    if ($Filter) {
        swift test --filter $Filter
    } else {
        swift test
    }
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
