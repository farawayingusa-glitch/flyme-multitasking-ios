param(
    [string]$Source = 'Tweak.xm',
    [string]$KeyboardSource = 'Keyboard.xm',
    [string]$LifecycleSource = 'SceneLifecycle.xm'
)

$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path, [string]$Text) {
    if (-not (Select-String -LiteralPath $Path -SimpleMatch $Text -Quiet)) {
        throw "Missing required repair marker in ${Path}: $Text"
    }
}

Require-Text $Source 'FLMFloatingLaunchTimeout = 6.5'
Require-Text $Source 'FLMFloatingSceneSettleDelay = 0.18'
Require-Text $Source 'FLMFloatingSceneGenerationDelay = 0.75'
Require-Text $Source 'FLMFloatingLaunchStateWaitingForScene'
Require-Text $Source 'failFloatingLaunchForIdentifier:'
Require-Text $Source 'generatingNewPrimarySceneIfRequired:generatePrimaryScene'
Require-Text $Source 'CACurrentMediaTime() - self.floatingLaunchStartedAt'
Require-Text $Source 'FLMFloatingSceneSettleDelay'
Require-Text $KeyboardSource 'window.windowLevel <= UIWindowLevelNormal + 1.0'
Require-Text $KeyboardSource '%hook UITextEffectsWindow'
Require-Text $KeyboardSource '- (CGRect)_referenceBounds'
Require-Text $LifecycleSource 'FLMClearProtectedScene(self);'

# The repair must retain a bounded escape route and must not add a direct
# SpringBoard keyboard-window hook (those are unsafe across iOS 16 point releases).
if (Select-String -LiteralPath $KeyboardSource -Pattern '^%hook UIWindow\s*$|^%hook UIRemoteKeyboardWindow\s*$|^%hook UIKeyboardWindow\s*$' -Quiet) {
    throw 'Unsafe direct keyboard-window hook detected.'
}

Write-Output 'lifecycle, launch, and keyboard repair markers verified'
