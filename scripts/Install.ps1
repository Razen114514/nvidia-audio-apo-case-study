$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$InstallDirectory = 'C:\ProgramData\AudioMode'
$ExecutableSource = Join-Path $Root 'dist\AudioModeTray.exe'
$IconSource = Join-Path $Root 'dist\AudioModeTray.ico'

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Path -LiteralPath $ExecutableSource) -or
    -not (Test-Path -LiteralPath $IconSource)) {
    & (Join-Path $PSScriptRoot 'Build.ps1')
}

if (-not (Test-IsAdmin)) {
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath
    )
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
}

New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null

$task = Get-ScheduledTask -TaskName 'AudioModeTray' -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName 'AudioModeTray' -ErrorAction SilentlyContinue
}
Get-Process -Name 'AudioModeTray' -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

Copy-Item -LiteralPath $ExecutableSource -Destination (Join-Path $InstallDirectory 'AudioModeTray.exe') -Force
Copy-Item -LiteralPath $IconSource -Destination (Join-Path $InstallDirectory 'AudioModeTray.ico') -Force
Copy-Item -LiteralPath (Join-Path $Root 'scripts\Fast-Switch-AudioMode.ps1') -Destination $InstallDirectory -Force
Copy-Item -LiteralPath (Join-Path $Root 'scripts\Set-G9SysFx.ps1') -Destination $InstallDirectory -Force

$action = New-ScheduledTaskAction `
    -Execute (Join-Path $InstallDirectory 'AudioModeTray.exe') `
    -WorkingDirectory $InstallDirectory
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal `
    -UserId ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME) `
    -LogonType Interactive `
    -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable

Register-ScheduledTask `
    -TaskName 'AudioModeTray' `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Audio mode tray switcher with global hotkeys.' `
    -Force | Out-Null

Start-ScheduledTask -TaskName 'AudioModeTray'
$running = $false
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    Start-Sleep -Milliseconds 250
    if (Get-Process -Name 'AudioModeTray' -ErrorAction SilentlyContinue) {
        $running = $true
        break
    }
    if ($attempt -eq 9) {
        Start-ScheduledTask -TaskName 'AudioModeTray'
    }
}
if (-not $running) {
    throw 'AudioModeTray was installed but did not stay running.'
}
Write-Host 'AudioModeTray installed and started.'
