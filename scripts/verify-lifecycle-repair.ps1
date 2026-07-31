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
Require-Text $Source '- (void)restoreFloatingHandleInteraction'
Require-Text $Source 'self.floatingHandle.userInteractionEnabled = YES;'
Require-Text $Source 'UIView *primaryControl = self.floatingPrimaryControlView;'
Require-Text $Source 'updateFloatingFullscreenSnapshotForProgress:'
Require-Text $Source 'wrapper.frame = frame;'
Require-Text $Source 'displayCommitted = targetIsFrontmost && attempt >= 1'
Require-Text $Source 'setFloatingApplicationInputBlocked:YES'
Require-Text $Source 'CGFloat handleWidth = visibleHandleWidth + 40.0;'
Require-Text $Source 'FLMPublishKeyboardState(self.floatingIdentifier, scene);'
Require-Text $KeyboardSource 'window.windowLevel <= UIWindowLevelNormal + 1.0'
Require-Text $KeyboardSource '%hook UITextEffectsWindow'
Require-Text $KeyboardSource '- (CGRect)_referenceBounds'
Require-Text $KeyboardSource 'FLMSceneMatchesKeyboardRoute'
Require-Text $KeyboardSource 'FLYME_KEYBOARD_SCENE_NOTIFICATION'
Require-Text $KeyboardSource 'FLYME_KEYBOARD_PREPARE_NOTIFICATION'
Require-Text $KeyboardSource '%hook UIResponder'
Require-Text $LifecycleSource 'FLMClearProtectedScene(self);'

if (Select-String -LiteralPath $Source -SimpleMatch 'BOOL minimumCoverTimeElapsed = attempt >= 8;' -Quiet) {
    throw 'Fixed fullscreen handoff stall was reintroduced.'
}

# The repair must retain a bounded escape route and must not add a direct
# SpringBoard keyboard-window hook (those are unsafe across iOS 16 point releases).
if (Select-String -LiteralPath $KeyboardSource -Pattern '^%hook UIWindow\s*$|^%hook UIRemoteKeyboardWindow\s*$|^%hook UIKeyboardWindow\s*$' -Quiet) {
    throw 'Unsafe direct keyboard-window hook detected.'
}

Write-Output 'lifecycle, launch, and keyboard repair markers verified'
