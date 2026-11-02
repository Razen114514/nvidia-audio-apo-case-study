param(
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist')
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Compiler = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$IconGenerator = Join-Path $PSScriptRoot 'Generate-AudioModeIcon.ps1'
$Icon = Join-Path $OutputDirectory 'AudioModeTray.ico'
$Preview = Join-Path $OutputDirectory 'AudioModeTray-icon-preview.png'
$Executable = Join-Path $OutputDirectory 'AudioModeTray.exe'
$BuildOutput = Join-Path $OutputDirectory 'AudioModeTray.next.exe'
$Manifest = Join-Path $Root 'src\AudioModeTray.manifest'
$TraySource = Join-Path $Root 'src\AudioModeTray.cs'
$EngineSource = Join-Path $Root 'src\AudioSwitchEngine.cs'

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

& $IconGenerator -OutputIco $Icon -OutputPreview $Preview

if (Test-Path -LiteralPath $BuildOutput) {
    Remove-Item -LiteralPath $BuildOutput -Force
}

& $Compiler `
    /nologo `
    /target:winexe `
    /platform:x64 `
    /optimize+ `
    /codepage:65001 `
    /out:$BuildOutput `
    /reference:System.Windows.Forms.dll `
    /reference:System.Drawing.dll `
    /reference:System.Management.dll `
    /win32manifest:$Manifest `
    /win32icon:$Icon `
    $TraySource `
    $EngineSource

if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $BuildOutput)) {
    throw "Build failed with exit code $LASTEXITCODE"
}

Move-Item -LiteralPath $BuildOutput -Destination $Executable -Force
Get-Item -LiteralPath $Executable,$Icon | Select-Object FullName,Length,LastWriteTime
