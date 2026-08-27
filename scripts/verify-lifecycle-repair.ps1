param(
    [string]$Source = 'Tweak.xm',
    [string]$LifecycleSource = 'SceneLifecycle.xm',
    [string]$KeyboardSource = 'Keyboard.xm',
    [string]$KeyboardFilter = 'FlymeKeyboard.plist'
)

$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path, [string]$Text) {
    if (-not (Select-String -LiteralPath $Path -SimpleMatch $Text -Quiet)) {
        throw "Missing required repair marker in ${Path}: $Text"
    }
}

function Reject-Text([string]$Path, [string]$Text) {
    if (Select-String -LiteralPath $Path -SimpleMatch $Text -Quiet) {
        throw "Rejected obsolete or unsafe marker in ${Path}: $Text"
    }
}

# Scene launch and gesture foundations remain frozen.
foreach ($Marker in @(
    'FLMFloatingLaunchTimeout = 6.5',
    'FLMFloatingSceneSettleDelay = 0.10',
    'FLMFloatingSceneGenerationDelay = 0.75',
    'FLMCenteredCardWidth = 315.0',
    'FLMCenteredCardTopCrop = 37.0',
    'FLMCenteredCardBottomCrop = 19.0',
    'FLMDefaultCenteredDockSwipeThreshold = 20.0',
    'FLMDockAnimationSpeed = 0.85',
    'failFloatingLaunchForIdentifier:',
    'generatingNewPrimarySceneIfRequired:generatePrimaryScene',
    'restoreFloatingHandleInteraction',
    'updateFloatingFullscreenSnapshotForProgress:',
    'displayCommitted = targetIsFrontmost && attempt >= 1',
    'CGFloat handleWidth = visibleHandleWidth + 40.0;',
    'pointIsInsideFloatingInteractionDomain:',
    'outsideCloseAuthorized',
    'flmOutsideCloseAuthorized',
    'UIKeyboardDidHideNotification',
    '@interface FLMKeyboardForwardingWindow : UIWindow',
    'window.windowLevel = self.floatingWindow.windowLevel + 1.0;',
    '[self.keyboardForwardingWindow makeKeyAndVisible];',
    '%hook _UIKeyboardLayerHostView',
    'didUpdateClientSettingsWithDiff:',
    '[forwardingRoot addSubview:hostView];',
    'sb frame-apply rejected=inactive-session',
    'sb session-end route-cleared',
    'updateClientSettingsWithBlock:',
    'setPreferredSceneHostIdentity:',
    'sb scene-pair apply=',
    'sb scene-pair clear=',
    'FLMPublishKeyboardState',
    'FLMPublishKeyboardAvoidance',
    'FLMPublishKeyboardCardGeometry',
    '0.24 * NSEC_PER_SEC',
    'finalizeKeyboardDismissalProtection',
    'sb frame-hidden protection=finalized',
    'floatingSceneUsesCardGeometry',
    'floatingSceneCardGeometryPending',
    'floatingSceneCardGeometryCommitted',
    'floatingSceneLogicalFrameMatchesSystemReference',
    'content-viewport request',
    'content-viewport committed',
    'scene-frame policy=fullscreen',
    'content-scale policy=%@ systemSceneReference=',
    'contentViewportReference=',
    'sceneFrameReference=system',
    'floatingSystemSceneReferenceSize',
    'floatingContentViewportReferenceSize',
    'frame-deferred waiting=scene-host',
    'host-deferred waiting=application-host',
    'frame-deferred replay=1'
)) {
    Require-Text $Source $Marker
}

foreach ($Removed in @(
    'applyFloatingKeyboardViewportAvoidance',
    'floatingKeyboardViewportApplied',
    'sb viewport committed',
    '%hook UIResponder',
    '%hook NSNotificationCenter',
    'FLYME_KEYBOARD_FRAME_NOTIFICATION',
    'FLYME_KEYBOARD_ROUTE_ACK_NOTIFICATION',
    'additionalSafeAreaInsets',
    'FLMApplyApplicationKeyboardSafeArea',
    'FLMCorrectKeyboardNotificationUserInfo',
    'applyFloatingKeyboardContainerOffsetForFrame:',
    '%hook UIWindowScene',
    '%hook UIKeyboardWindow',
    'FLMRequestApplicationKeyboardDismiss',
    'floatingKeyboardRouteReadyGeneration',
    'finalizeFloatingKeyboardSessionEnd:',
    'route-not-ready',
    'consumeOutsideTapForKeyboardDismissal',
    'applyFloatingKeyboardContainerOffsetForFrame:',
    'floatingKeyboardContainerOffsetY',
    'setFloatingSceneUsesFullscreenKeyboardHost',
    'widthCompletion',
    'verticalRevealStart',
    'widthProgress',
    'verticalProgress',
    'fillScale',
    'scene-virtual-viewport',
    'floatingSceneLogicalFrameMatchesVirtualViewport',
    'virtual-viewport-fit',
    'virtual-viewport restore keyboard-session-restored'
)) {
    Reject-Text $Source $Removed
}

Require-Text $LifecycleSource 'FLMClearProtectedScene(self);'
foreach ($Marker in @(
    '%hook UITextEffectsWindow',
    'keyboardScreenReferenceSize',
    '%hook _UIRemoteKeyboards',
    'intersectionHeightForWindowScene:',
    'FLMExternalKeyboardAvoidanceHeight',
    'FLMDiagnosticEventIntersection'
)) {
    Require-Text $KeyboardSource $Marker
}
foreach ($Marker in @(
    'FLMHandleKeyboardDismissRequest',
    'FLMResignTargetApplicationResponder',
    'FLMSendKeyboardDismissAck',
    'FLYME_KEYBOARD_DISMISS_REQUEST_NOTIFICATION',
    'FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION',
    'sendAction:@selector(resignFirstResponder)',
    '[window endEditing:YES]',
    'adapter-ctor',
    'adapter-ready'
)) {
    Require-Text $KeyboardSource $Marker
}
Require-Text $KeyboardSource 'FLMApplicationProcessIdentityFlags'
Require-Text $KeyboardSource 'FLMIsExplicitWeChatAdapterProcess'
Require-Text $KeyboardSource 'FLMProcessIsApplicationClient'
Require-Text $KeyboardSource 'FLMContentLogicalViewportSize'
Require-Text $KeyboardSource 'FLMPhysicalCardSize'
Require-Text $KeyboardSource 'FLMContentViewportAdapter'
Require-Text $KeyboardSource 'FLMHandleKeyboardRouteNotification'
Require-Text $KeyboardSource 'FLMReloadContentViewportSelection'
Require-Text $KeyboardSource 'FLMProcessIsSpringBoardOrSystemAgent'
Require-Text $KeyboardSource 'return MAX(originalHeight, mappedHeight);'
Require-Text $KeyboardSource 'FLMReadKeyboardSharedState'
Require-Text $KeyboardSource 'FLYME_KEYBOARD_SHARED_STATE_VERSION 3'
Require-Text $KeyboardSource 'dictionaryWithContentsOfFile:FLMKeyboardSharedStatePath'
Require-Text $KeyboardSource 'FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION'
Require-Text $KeyboardSource 'FLMPublishKeyboardAppLifecycleStage'
Require-Text $KeyboardSource 'FLMDiagnosticEventAdapterCtor'
Require-Text $KeyboardSource 'FLMDiagnosticEventAdapterReady'
Require-Text $Source 'floatingKeyboardMaximumVisibleHeight'
Require-Text $Source 'avoidance-retained=1'
Require-Text $Source 'FLYME_DIAGNOSTIC_APPLICATION_NOTIFICATION'
Require-Text $Source 'FLMScheduleKeyboardSharedStateWrite'
Require-Text $Source 'NSPropertyListBinaryFormat_v1_0'
Require-Text $Source '@"version": @3'
Require-Text $Source 'notify_post(FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION);'
Require-Text $Source 'FLMKeyboardAppAdapterReadyForIdentifier'
Require-Text $Source 'FLMPublishKeyboardDismissRequest'
Require-Text $Source 'beginKeyboardCoordinatedCloseWithToken'
Require-Text $Source 'handleApplicationDismissAck'
Require-Text $Source 'handleKeyboardSettlementForCloseToken'
Require-Text $Source 'commitCoordinatedCloseForToken'
Require-Text $Source 'abortCoordinatedCloseForToken'
Require-Text $Source 'FLMFloatingKeyboardCloseStateAwaitingAdapter'
Require-Text $Source 'FLMFloatingKeyboardCloseStateAwaitingKeyboardSettlement'
Require-Text $Source 'FLMFloatingKeyboardCloseStateFinalizing'
Require-Text $Source 'FLMFloatingKeyboardDismissTimeout = 1.90;'
Require-Text $Source 'FLMKeyboardCloseContext'
Require-Text $Source 'floatingKeyboardCloseContext'
Require-Text $Source 'dismissRequestGeneration'
Require-Text $Source 'dismissAckGeneration'
Require-Text $Source 'FLMKeyboardHitTestSlop'
Require-Text $Source 'dock-transition-takeover'
Require-Text $Source 'transitionTakeover=enabled'
Require-Text $Source 'UIViewPropertyAnimator'
Reject-Text $Source 'transitionTakeover=disabled'
Reject-Text $Source 'FLMKeyboardAccessoryProtectionHeight'
Require-Text $Source 'sb coordinated-close commit'
Require-Text $Source 'sb coordinated-close abort'
Require-Text $Source 'sb keyboard-settlement frame-hidden'
Require-Text $Source 'adapterReady=deferred adapterPID=deferred'
Require-Text $Source 'filter=target-bundle target-gated'
Require-Text $Source 'floatingCloseInProgress'
Require-Text $Source 'finishFloatingCloseWithToken:'
Require-Text $Source 'floatingQueuedIdentifier'
Require-Text $Source 'sb centered-close cleanup-once'
Require-Text $Source 'sb presenter-stale-retry'
Require-Text $Source 'FLMVirtualViewportWidth = 390.0'
Require-Text $Source 'FLMVirtualViewportHeight = 844.0'
Require-Text $Source 'effectiveCenteredCardScaleX'
Require-Text $Source 'effectiveCenteredCardScaleY'
Require-Text $Source 'uniformScale'
Require-Text $Source 'cardWidth'
Require-Text $Source 'cardHeight'
Require-Text $Source 'contentViewportHeight'
Require-Text $Source 'CGAffineTransformMakeScale(scaleX, scaleY)'
Require-Text $Source 'targetPhysicalCard={'
Require-Text $Source 'scaleXY={'
Require-Text $Source 'scene-frame policy=fullscreen'
Require-Text $Source 'content-scale policy=%@ systemSceneReference='
Require-Text $Source 'contentViewportReference='
Require-Text $Source 'sceneFrameReference=system'
Require-Text $Source 'floatingHostReferenceSize'
Require-Text $Source 'applyFloatingSceneLogicalFrameForCurrentPresentation'
Require-Text $Source 'floatingFullscreenProgress'
Require-Text $Source 'geometryProgress'
Require-Text $Source 'restoring-card=1'
Require-Text $Source 'host.clipsToBounds = NO'
Require-Text $Source 'ctor={reg:%d read:%d raw:'
Require-Text $Source 'policy=touch-origin'
Require-Text $Source 'centered-preserved=%d'
Require-Text $Source 'sb presenter-watchdog fallback=fullscreen'
Require-Text $Source 'launch-cover recovery-failed'
Require-Text $Source 'fullscreen-fallback dequeue target'
Require-Text $Source 'floatingQueuedFullscreenIdentifier'
Require-Text $Source 'dockedHiddenFloatingFrameOnRight'
Require-Text $Source 'floatingDockHideGestureActive'
Require-Text $Source 'floatingDockHideReady'
Require-Text $Source 'finishFloatingDockHiddenGesture'
Require-Text $Source 'effectiveCenteredDockSwipeThreshold'
Require-Text $Source 'effectiveDockedPresentationWidth'
Require-Text $KeyboardSource 'BOOL shouldApply = NO;'
Require-Text $KeyboardSource 'if (currentHash == FLMKeyboardTargetSceneHash)'
Require-Text $Source 'sb host-update rejected=alternate-host'
foreach ($Removed in @(
    'floatingKeyboardReopenGuardIdentifier',
    'sb reopen-keyboard-guard',
    'stale-keyboard',
    'FLMFloatingKeyboardReopenObservationDelay',
    'FLMFloatingKeyboardReopenGuardTimeout'
)) {
    Reject-Text $Source $Removed
}
Reject-Text $Source 'content-scale policy=card-fit'
Reject-Text $Source 'content-scale policy=card-1to1'
Reject-Text $Source 'scene-card commit-request'
Reject-Text $Source 'scene-card committed'
Reject-Text $Source 'card-fit=1'
Reject-Text $Source 'FLMVirtualViewportScale'
Reject-Text $Source '0.50 * NSEC_PER_SEC'
Require-Text $KeyboardFilter '<key>Bundles</key>'
Require-Text $KeyboardFilter '<string>com.apple.UIKit</string>'
Require-Text $KeyboardFilter '<string>com.tencent.xin</string>'
Reject-Text $KeyboardFilter '<key>Executables</key>'
Reject-Text $KeyboardFilter '<key>Classes</key>'
Write-Output 'scene lifecycle, full-screen crop presentation, single-host keyboard route, bounded launch recovery, and hidden-dock interaction verified'
