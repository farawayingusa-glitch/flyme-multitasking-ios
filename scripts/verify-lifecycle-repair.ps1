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
    'FLMLogBuildString @"Stable build 0.9.52"',
    'logger-ready build=%@ schema=27',
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
    'tap-deferred',
    'floatingDockTap',
    'handleFloatingDockTap',
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
    'virtual-viewport restore keyboard-session-restored',
    'FLYME_KEYBOARD_ROUTE_CHANNEL_PREFIX',
    'FLMKeyboardRouteChannel',
    'FLMKeyboardRouteChannelName',
    'FlymeRouteChanged.',
    'fanout=bundle'
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
Require-Text $KeyboardSource 'FLYME_KEYBOARD_SHARED_STATE_VERSION 5'
Require-Text $KeyboardSource 'dictionaryWithContentsOfFile:FLMKeyboardSharedStatePath'
Require-Text $KeyboardSource 'FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION'
Require-Text $KeyboardSource 'FLMPublishKeyboardAppLifecycleStage'
Require-Text $KeyboardSource 'FLMDiagnosticEventAdapterCtor'
Require-Text $KeyboardSource 'FLMDiagnosticEventAdapterReady'
Require-Text $KeyboardSource 'FLMProcessGlobalTransportBootstrap'
Require-Text $KeyboardSource 'FLMKeyboardTransportChannelState'
Require-Text $KeyboardSource 'FLMKeyboardTransportChannels'
Require-Text $KeyboardSource 'FLMKeyboardTransportRetryDelays'
Require-Text $KeyboardSource 'FLMEnsureKeyboardObserversRegistered'
Require-Text $KeyboardSource 'FLMClaimKeyboardDismissGeneration'
Require-Text $KeyboardSource 'FLMDiagnosticEventTransportRegister'
Require-Text $KeyboardSource 'FLMDiagnosticEventTransportReady'
Require-Text $KeyboardSource 'FLMDiagnosticEventTransportReceiveDismiss'
Require-Text $KeyboardSource 'FLMDiagnosticEventTransportReceiveRoute'
Require-Text $KeyboardSource 'FLMDiagnosticEventDismissClaim'
Require-Text $KeyboardSource 'FLMDiagnosticEventResponderActionBegin'
Require-Text $KeyboardSource 'FLMDiagnosticEventResponderActionComplete'
Reject-Text $KeyboardSource 'NSLog(@"[FlymeKeyboard] keyboard-transport'
Reject-Text $KeyboardSource 'NSLog(@"[FlymeKeyboard] transport-recv'
Require-Text $KeyboardSource 'FLMKeyboardLastRouteGeneration'
Require-Text $KeyboardSource 'FLMKeyboardLastGeometryGeneration'
Require-Text $KeyboardSource 'FLMKeyboardLastDismissGeneration'
Require-Text $KeyboardSource 'FLMKeyboardLastProcessedSession'
Require-Text $KeyboardSource 'route-applied'
Require-Text $KeyboardSource 'process-ready-once'
Require-Text $KeyboardSource 'application dismiss-request received count=1'
Require-Text $KeyboardSource 'target-validation result=process-match'
Require-Text $KeyboardSource 'responder-resign begin'
Require-Text $KeyboardSource 'responder-resign end'
Require-Text $KeyboardSource 'scene-fallback-success'
Require-Text $KeyboardSource 'stale-generation'
Require-Text $KeyboardSource 'wrong-process'
Require-Text $Source 'floatingKeyboardMaximumVisibleHeight'
Require-Text $Source 'avoidance-retained=1'
Require-Text $Source 'FLYME_DIAGNOSTIC_APPLICATION_NOTIFICATION'
Require-Text $Source 'FLMScheduleKeyboardSharedStateWrite'
Require-Text $Source 'NSPropertyListBinaryFormat_v1_0'
Require-Text $Source '@"version": @5'
Require-Text $Source 'notify_post(FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION);'
Require-Text $Source 'FLMKeyboardAppAdapterReadyForIdentifier'
Require-Text $Source 'FLMPublishKeyboardDismissRequest'
Require-Text $Source 'beginKeyboardCoordinatedCloseWithToken'
Require-Text $Source 'handleApplicationDismissAck'
Require-Text $Source 'handleKeyboardSettlementForCloseToken'
Require-Text $Source 'commitCoordinatedCloseForToken'
Require-Text $Source 'abortCoordinatedCloseForToken'
Require-Text $Source 'FLMFloatingKeyboardCloseStateAwaitingAppClaim'
Require-Text $Source 'FLMFloatingKeyboardCloseStateAwaitingKeyboardSettlement'
Require-Text $Source 'FLMFloatingKeyboardCloseStateCommit'
Require-Text $Source 'FLMFloatingKeyboardCloseStateAborted'
Require-Text $Source 'FLMFloatingKeyboardAppClaimTimeout = 0.70;'
Require-Text $Source 'FLMFloatingKeyboardSettlementTimeout = 1.50;'
Require-Text $Source 'FLMKeyboardDismissAckPhaseClaimed'
Require-Text $Source 'dismissAckPhase'
Require-Text $Source 'FLMKeyboardCloseContext'
Require-Text $Source 'floatingKeyboardCloseContext'
Require-Text $Source 'dismissRequestGeneration'
Require-Text $Source 'dismissAckGeneration'
Require-Text $Source 'FLMKeyboardHitTestSlop'
Require-Text $Source 'dock-transition-takeover'
Require-Text $Source 'presentationPosition='
Require-Text $Source 'presentationScale='
Require-Text $Source 'dock-tap recognized'
Require-Text $Source 'dock-restore begin'
Require-Text $Source 'dock-restore complete transition=render-server'
Require-Text $Source 'CAAnimationGroup'
Require-Text $Source 'transform.scale'
Require-Text $Source 'flyme.dock.restore.presentation'
Require-Text $Source 'outer PresentationContainer'
Require-Text $Source 'floatingDockPresentationScale'
Require-Text $Source 'floatingContainerPresentationFrame'
Require-Text $Source 'FLYME_KEYBOARD_NOTIFICATION'
Require-Text $Source 'routeChannel=global fanout=global'
Require-Text $Source 'restore-content-scale stable='
Require-Text $Source 'presentationContainerScale='
Require-Text $Source 'remoteContentScale='
Require-Text $Source 'session-fixed'
Require-Text $Source 'remoteHostUnchanged=1'
Require-Text $Source 'transitionTakeover=enabled'
Require-Text $Source 'UIViewPropertyAnimator'
Require-Text $Source 'floatingDockDisplayLinkCapped60'
Require-Text $Source 'FLMFloatingDockRendererModeDirectPan'
Require-Text $Source 'applyFloatingDockDirectPanPoint:'
Require-Text $Source 'avgInputDelta='
Require-Text $Source 'avgRenderDelta='
Require-Text $Source 'effectiveRenderFPS='
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
Require-Text $Source 'sb close-intent begin'
Require-Text $Source 'sb close-intent ignored=pending-close'
Require-Text $Source 'route-publish once=1'
Require-Text $Source 'dock-displaylink-config'
Require-Text $Source 'prepareFloatingDockDisplayLink'
Require-Text $Source 'setFloatingDockDisplayLinkActive'
Require-Text $Source 'CAFrameRateRangeMake'
Require-Text $Source 'preferredFrameRateRange'
Require-Text $Source 'NSRunLoopCommonModes'
Require-Text $Source 'runLoopMode=CommonModes'
Require-Text $Source 'paused=1'
Require-Text $Source 'screenMaxFPS='
Require-Text $Source 'requestedMinFPS='
Require-Text $Source 'requestedMaxFPS='
Require-Text $Source 'requestedPreferredFPS='
Require-Text $Source 'actualCallbackDelta:'
Require-Text $Source 'targetDelta:'
Require-Text $Source 'renderFrames'
Require-Text $Source 'missedVsync'
Require-Text $Source 'effectiveFPS'
Require-Text $Source 'dock-presentation geometry-suppressed=1'
Require-Text $Source 'dock-snap-complete transition=position-only'
Require-Text $Source 'contentViewportCommitted'
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
Reject-Text $Source 'wrong-target'
Reject-Text $Source 'centered-close no-op'
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
