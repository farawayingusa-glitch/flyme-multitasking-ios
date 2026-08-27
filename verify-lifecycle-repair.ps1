param(
    [string]$Source = 'Tweak.xm',
    [string]$LifecycleSource = 'SceneLifecycle.xm',
    [string]$KeyboardSource = 'Keyboard.xm',
    [string]$KeyboardFilter = 'FlymeKeyboard.plist'
)

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'scripts\verify-lifecycle-repair.ps1'
$sourcePath = Join-Path (Get-Location) $Source
$lifecycleSourcePath = Join-Path (Get-Location) $LifecycleSource
$keyboardSourcePath = Join-Path (Get-Location) $KeyboardSource
$keyboardFilterPath = Join-Path (Get-Location) $KeyboardFilter
$powershellPath = (Get-Command powershell.exe).Source
& $powershellPath -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Source $sourcePath -LifecycleSource $lifecycleSourcePath -KeyboardSource $keyboardSourcePath -KeyboardFilter $keyboardFilterPath
exit $LASTEXITCODE
