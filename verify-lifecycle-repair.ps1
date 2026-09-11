param(
    [string]$Source = 'Tweak.xm',
    [string]$LifecycleSource = 'SceneLifecycle.xm',
    [string]$KeyboardSource = 'Keyboard.xm',
    [string]$KeyboardFilter = 'FlymeKeyboard.plist'
)
# Keep one canonical lifecycle verifier; the former duplicate required stale 0.18s timing.
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'scripts/verify-lifecycle-repair.ps1') @PSBoundParameters
