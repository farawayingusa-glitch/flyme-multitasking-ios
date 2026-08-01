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
Require-Text $Source 'pointIsInsideFloatingInteractionDomain:'
Require-Text $Source 'self.floatingExclusiveTapEligible &&'
Require-Text $Source 'UIKeyboardDidHideNotification'
Require-Text $Source 'FLYME_KEYBOARD_SESSION_NOTIFICATION'
Require-Text $Source 'floatingKeyboardSessionGeneration'
Require-Text $KeyboardSource '%hook UITextEffectsWindow'
Require-Text $KeyboardSource '- (CGRect)_referenceBounds'
Require-Text $KeyboardSource 'FLMSceneMatchesKeyboardRoute'
Require-Text $KeyboardSource 'FLYME_KEYBOARD_SCENE_NOTIFICATION'
Require-Text $KeyboardSource 'FLYME_KEYBOARD_SESSION_NOTIFICATION'
Require-Text $KeyboardSource '%hook UIResponder'
Require-Text $KeyboardSource 'UIKeyboardDidHideNotification'
Require-Text $KeyboardSource 'UIKeyboardWillHideNotification'
Require-Text $KeyboardSource '%group FLMRemoteKeyboardGeometry'
Require-Text $KeyboardSource 'intersectionHeightForWindowScene:'
Require-Text $KeyboardSource 'originalHeight + physicalHeight - sceneHeight'
Require-Text $KeyboardSource '_referenceBounds must remain UIKit-owned'
Require-Text $KeyboardSource 'FLMEndingApplicationKeyboardSession'
Require-Text $KeyboardSource '- (BOOL)resignFirstResponder'
Require-Text $Source 'const CGFloat widthCompletion = 0.82;'
Require-Text $Source 'const CGFloat verticalRevealStart = 0.22;'
Require-Text $Source 'background.alpha = verticalProgress > 0.0001 ? 1.0 : 0.0;'
Require-Text $Source '[UIView performWithoutAnimation:^{'
Require-Text $Source 'endFloatingKeyboardSession'
Require-Text $Source 'floatingLaunchCoverView'
Require-Text $Source 'revealFloatingContentForGeneration'
Require-Text $KeyboardSource 'FLMKeyboardActiveTextResponder'
Require-Text $Source 'resolvedScene != self.floatingScene'
Require-Text $Source 'needsInitialSceneSettle'
Require-Text $Source '0.50 * NSEC_PER_SEC'
Require-Text $Source 'FLYME_KEYBOARD_DISMISS_NOTIFICATION'
Require-Text $Source 'consumeOutsideTapForKeyboardDismissal'
Require-Text $KeyboardSource 'connectedScenes.count <= 1'
Require-Text $KeyboardSource 'FLMResignFirstResponderInView'
Require-Text $Source 'FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION'
Require-Text $KeyboardSource 'FLMKeyboardEndedSessionGeneration'
Require-Text $KeyboardSource 'sendAction:@selector(resignFirstResponder)'
Require-Text $Source '@interface FLMKeyboardForwardingWindow : UIWindow'
Require-Text $Source 'window.windowLevel = 45.0;'
Require-Text $Source 'initWithWindowScene:targetWindowScene'
Require-Text $Source 'setAutorotates:forceUpdateInterfaceOrientation:'
Require-Text $Source 'hitView == self || hitView == rootView'
Require-Text $Source '%hook _UIKeyboardLayerHostView'
Require-Text $Source 'didUpdateClientSettingsWithDiff:'
Require-Text $Source '[forwardingRoot addSubview:hostView];'
Require-Text $Source '[self discardFloatingKeyboardLayerHost];'
Require-Text $LifecycleSource 'FLMClearProtectedScene(self);'

foreach ($RemovedKeyboardPatch in @(
    'FLMRemoteKeyboardAvoidance',
    'FLMApplyCorrectedKeyboardOcclusion',
    'postNotificationName:UIKeyboardWillChangeFrameNotification',
    '@interface FLMKeyboardOverlayWindow',
    '@interface FLMKeyboardHostBridgeView',
    'FLMPublishKeyboardOcclusion'
)) {
    if ((Select-String -LiteralPath $KeyboardSource -SimpleMatch $RemovedKeyboardPatch -Quiet) -or
        (Select-String -LiteralPath $Source -SimpleMatch $RemovedKeyboardPatch -Quiet)) {
        throw "Removed keyboard patch architecture was reintroduced: $RemovedKeyboardPatch"
    }
}

if (Select-String -LiteralPath $Source -SimpleMatch 'BOOL minimumCoverTimeElapsed = attempt >= 8;' -Quiet) {
    throw 'Fixed fullscreen handoff stall was reintroduced.'
}

# The repair must retain a bounded escape route and must not hook keyboard
# UIWindow classes themselves. The forwarding path observes only the layer
# host's completed client-settings transaction.
if (Select-String -LiteralPath $KeyboardSource -Pattern '^%hook UIWindow\s*$|^%hook UIRemoteKeyboardWindow\s*$|^%hook UIKeyboardWindow\s*$' -Quiet) {
    throw 'Unsafe direct keyboard-window hook detected.'
}

if (Select-String -LiteralPath $KeyboardSource -SimpleMatch '%hook UIWindowScene' -Quiet) {
    throw 'Application Scene reference bounds are being overridden again.'
}

if (Select-String -LiteralPath $Source -SimpleMatch 'setFloatingSceneUsesFullscreenKeyboardHost' -Quiet) {
    throw 'Whole application Scene keyboard expansion was reintroduced.'
}

foreach ($unsafeKeyboardLine in @(
    '- (void)didMoveToWindow',
    'FLMKeyboardPreparePosted',
    'floatingReusableKeyboardLayerHostView',
    'scheduleFloatingKeyboardLayerHostDetach',
    'FLMKeyboardDiagnosticLog'
)) {
    if ((Select-String -LiteralPath $Source -SimpleMatch $unsafeKeyboardLine -Quiet) -or
        (Select-String -LiteralPath $KeyboardSource -SimpleMatch $unsafeKeyboardLine -Quiet)) {
        throw "Unsafe or one-shot keyboard path detected: $unsafeKeyboardLine"
    }
}

Write-Output 'lifecycle, launch, and keyboard repair markers verified'
