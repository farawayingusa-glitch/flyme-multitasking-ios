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
Require-Text $Source 'MIN(0.93, MAX(0.0, primaryMovement / available))'
Require-Text $Source 'background.alpha = heightStage > 0.0001 ? 1.0 : 0.0;'
Require-Text $Source 'displayCommitted = targetIsFrontmost && attempt >= 1'
Require-Text $Source 'setFloatingApplicationInputBlocked:YES'
Require-Text $Source 'CGFloat handleWidth = visibleHandleWidth + 40.0;'
Require-Text $Source 'pointIsInsideFloatingInteractionDomain:'
Require-Text $Source 'self.floatingExclusiveTapEligible &&'
Require-Text $Source 'UIKeyboardDidHideNotification'
Require-Text $Source 'FLMPublishKeyboardState(self.floatingIdentifier, scene);'
Require-Text $KeyboardSource '%hook UITextEffectsWindow'
Require-Text $KeyboardSource '- (CGRect)_referenceBounds'
Require-Text $KeyboardSource 'FLMSceneMatchesKeyboardRoute'
Require-Text $KeyboardSource 'FLYME_KEYBOARD_SCENE_NOTIFICATION'
Require-Text $KeyboardSource 'FLYME_KEYBOARD_PREPARE_NOTIFICATION'
Require-Text $KeyboardSource 'FLYME_FLOATING_GEOMETRY_NOTIFICATION'
Require-Text $KeyboardSource '%hook _UIRemoteKeyboards'
Require-Text $KeyboardSource 'presentationScale'
Require-Text $KeyboardSource '%hook UIResponder'
Require-Text $KeyboardSource 'UIKeyboardDidHideNotification'
Require-Text $Source '@interface FLMKeyboardOverlayWindow'
Require-Text $Source 'keyboardLayerHostView:'
Require-Text $Source 'floatingKeyboardCandidateHostView'
Require-Text $Source '%hook _UIKeyboardLayerHostView'
Require-Text $Source '- (void)didMoveToWindow'
Require-Text $Source 'valueForKey:@"_owningScene"'
Require-Text $Source 'valueForKey:@"_keyboardScene"'
Require-Text $Source 'floatingKeyboardOriginalSuperview'
Require-Text $Source 'pairing timeout; promoting'
Require-Text $Source 'const CGFloat widthStageEnd = 0.72;'
Require-Text $LifecycleSource 'FLMClearProtectedScene(self);'

if (Select-String -LiteralPath $Source -SimpleMatch 'BOOL minimumCoverTimeElapsed = attempt >= 8;' -Quiet) {
    throw 'Fixed fullscreen handoff stall was reintroduced.'
}

# The repair must retain a bounded escape route and must not add a direct
# SpringBoard keyboard-window hook (those are unsafe across iOS 16 point releases).
if (Select-String -LiteralPath $KeyboardSource -Pattern '^%hook UIWindow\s*$|^%hook UIRemoteKeyboardWindow\s*$|^%hook UIKeyboardWindow\s*$' -Quiet) {
    throw 'Unsafe direct keyboard-window hook detected.'
}

if (Select-String -LiteralPath $KeyboardSource -SimpleMatch '%hook UIWindowScene' -Quiet) {
    throw 'Application Scene reference bounds are being overridden again.'
}

if (Select-String -LiteralPath $Source -SimpleMatch 'setFloatingSceneUsesFullscreenKeyboardHost' -Quiet) {
    throw 'Whole application Scene keyboard expansion was reintroduced.'
}

if ((Select-String -LiteralPath $Source -SimpleMatch 'const CGFloat settleProgress = 0.985;' -Quiet) -or
    (Select-String -LiteralPath $Source -SimpleMatch '0.985 + 0.00042' -Quiet)) {
    throw 'Multi-stage fullscreen geometry handoff was reintroduced.'
}

Write-Output 'lifecycle, launch, and keyboard repair markers verified'
