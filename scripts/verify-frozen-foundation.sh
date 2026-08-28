#!/usr/bin/env bash
set -euo pipefail

source_file="${1:-Tweak.xm}"
keyboard_source="${2:-Keyboard.xm}"
keyboard_filter="${3:-FlymeKeyboard.plist}"

require_source() {
    local marker="$1"
    grep -Fq -- "$marker" "$source_file" || {
        echo "missing SpringBoard marker: $marker" >&2
        exit 1
    }
}

reject_source() {
    local marker="$1"
    if grep -Fq -- "$marker" "$source_file"; then
        echo "obsolete card/content path returned: $marker" >&2
        exit 1
    fi
}

for marker in \
    "static const CGFloat FLMDefaultCornerTriggerSize = 58.0;" \
    "static const CGFloat FLMMinimumCornerTriggerSize = 36.0;" \
    "static const CGFloat FLMMaximumCornerTriggerSize = 96.0;" \
    "CGFloat verticalRadius = horizontalRadius * (65.0 / 58.0);" \
    "FLMCopyPreference(@\"cornerTriggerSizeV2\")" \
    "self.hotspotWindow.windowLevel = UIWindowLevelAlert + 120.0;" \
    "if (!self.hotspotsEnabled)" \
    "self.hotspotWindow.hotspotsEnabled = canReceive &&" \
    "self.hotspotWindow.hidden = !self.enabled || self.usesSystemGestureManager;" \
    "addGestureRecognizer:self.cornerGesture toDisplayWithIdentity:identity" \
    "refreshWheelPriorityWindow" \
    "wheel-priority-touch" \
    "hotspotWindow.hotspotsEnabled = NO" \
    "self.cornerGesture.minimumPressDuration = 0.12;" \
    "self.cornerGuardGesture.minimumPressDuration = 0.0;" \
    "CGPoint rawPoint = [touch locationInView:nil];" \
    "CGPoint rawPoint = [gesture locationInView:nil];" \
    "return totalMovement >= 14.0 &&" \
    "static const CGFloat FLMDefaultWheelRadius = 202.0;" \
    "static const CGFloat FLMDefaultWheelIconSize = 56.0;" \
    "static const CGFloat FLMCenteredCardWidth = 315.0;" \
    "static const CGFloat FLMCenteredCardTopCrop = 37.0;" \
    "static const CGFloat FLMCenteredCardBottomCrop = 19.0;" \
    "static const CGFloat FLMMinimumCenteredCardWidth = 240.0;" \
    "static const CGFloat FLMMaximumCenteredCardWidth = 360.0;" \
    "static const CGFloat FLMVirtualViewportWidth = 390.0;" \
    "static const CGFloat FLMVirtualViewportHeight = 844.0;" \
    "static const CGFloat FLMDefaultCenteredDockSwipeThreshold = 20.0;" \
    "static const CGFloat FLMMinimumDockPresentationWidth = 96.0;" \
    "static const CGFloat FLMDockAnimationSpeed = 0.85;" \
    "effectiveCenteredCardScaleX" \
    "effectiveCenteredCardScaleY" \
    "effectiveCenteredDockSwipeThreshold" \
    "effectiveDockedPresentationWidth" \
    "uniformScale" \
    "CGAffineTransformMakeScale(scaleX, scaleY)" \
    "targetPhysicalCard={" \
    "scaleXY={" \
    "scene-frame policy=fullscreen" \
    "content-scale policy=%@ systemSceneReference=" \
    "sceneFrameReference=system" \
    "floatingSystemSceneReferenceSize" \
    "floatingContentViewportReferenceSize" \
    "floatingSceneUsesCardGeometry" \
    "floatingSceneCardGeometryPending" \
    "floatingSceneCardGeometryCommitted" \
    "floatingKeyboardFramePending" \
    "frame-deferred waiting=scene-host" \
    "host-deferred waiting=application-host" \
    "frame-deferred replay=1" \
    "floatingKeyboardSessionGeneration" \
    "sb frame-apply rejected=inactive-session" \
    "sb session-end route-cleared" \
    "FLMPublishKeyboardState" \
    "FLMPublishKeyboardAvoidance" \
    "FLMPublishKeyboardCardGeometry" \
    "FLMScheduleKeyboardSharedStateWrite" \
    "floatingCloseInProgress" \
    "finishFloatingCloseWithToken:" \
    "floatingQueuedIdentifier" \
    "floatingQueuedFullscreenIdentifier" \
    "sb centered-close cleanup-once" \
    "sb presenter-stale-retry" \
    "sb presenter-watchdog fallback=fullscreen" \
    "launch-cover recovery-failed" \
    "fullscreen-fallback dequeue target" \
    "dockedHiddenFloatingFrameOnRight" \
    "floatingDockHidden" \
    "floatingDockHideGestureActive" \
    "floatingDockHideReady" \
    "floatingContainerPresentationFrame" \
    "if (clearHorizontalIntent)" \
    "finishFloatingDockHiddenGesture" \
    "triggerProgress" \
    "floatingDockFeedbackSent" \
    "updateFloatingFullscreenSnapshotForProgress" \
    "floatingFullscreenProgress" \
    "CGFloat handleWidth = visibleHandleWidth + 40.0;" \
    "keyboardPassThroughFrame" \
    "FLMKeyboardHitTestSlop" \
    "CGRectIntersection(bounds, self.floatingKeyboardFrame)" \
    "FLMKeyboardCloseContext" \
    "floatingKeyboardCloseContext" \
    "dismissRequestGeneration" \
    "dismissAckGeneration" \
    "route-publish once=1" \
    "sb close-intent begin" \
    "sb close-intent ignored=pending-close" \
    "dock-state-publish once=1 presentationMode=Docked" \
    "dock-displaylink-config" \
    "prepareFloatingDockDisplayLink" \
    "setFloatingDockDisplayLinkActive" \
    "CAFrameRateRangeMake" \
    "preferredFrameRateRange" \
    "NSRunLoopCommonModes" \
    "runLoopMode=CommonModes" \
    "paused=1" \
    "screenMaxFPS=" \
    "requestedMinFPS=" \
    "requestedMaxFPS=" \
    "requestedPreferredFPS=" \
    "actualCallbackDelta:" \
    "targetDelta:" \
    "renderFrames" \
    "missedVsync" \
    "effectiveFPS" \
    "dock-presentation geometry-suppressed=1" \
    "dock-snap-complete transition=position-only" \
    "contentViewportCommitted" \
    "DockControlOverlay" \
    "dock-transition-takeover" \
    "presentationPosition=" \
    "presentationScale=" \
    "dock-tap recognized" \
    "dock-restore begin" \
    "dock-restore complete transition=render-server" \
    "CAAnimationGroup" \
    "transform.scale" \
    "flyme.dock.restore.presentation" \
    "outer PresentationContainer" \
    "floatingDockPresentationScale" \
    "FLYME_KEYBOARD_NOTIFICATION" \
    "routeChannel=global fanout=global" \
    "restore-content-scale stable=" \
    "presentationContainerScale=" \
    "remoteContentScale=" \
    "session-fixed" \
    "remote-host-unchanged=1" \
    "UIViewPropertyAnimator" \
    "floatingDockTransitionAnimator" \
    "route-kept=1" \
    "transitionTakeover=enabled"; do
    require_source "$marker"
done

for marker in \
    "FLMFloatingKeyboardDismissTimeout = 1.90;" \
    "FLYME_KEYBOARD_DISMISS_REQUEST_NOTIFICATION" \
    "FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION" \
    "FLMFloatingKeyboardCloseStateAwaitingAdapter" \
    "FLMFloatingKeyboardCloseStateAwaitingKeyboardSettlement" \
    "FLMFloatingKeyboardCloseStateFinalizing" \
    "beginKeyboardCoordinatedCloseWithToken" \
    "handleApplicationDismissAck" \
    "handleKeyboardSettlementForCloseToken" \
    "commitCoordinatedCloseForToken" \
    "abortCoordinatedCloseForToken" \
    "FLMPublishKeyboardDismissRequest" \
    "FLMKeyboardAppAdapterReadyForIdentifier" \
    "FLMKeyboardDismissResultSuccess" \
    "sb keyboard-settlement frame-hidden" \
    "sb coordinated-close commit" \
    "sb coordinated-close abort"; do
    require_source "$marker"
done

for marker in \
    "tap-deferred" \
    "floatingDockTap" \
    "handleFloatingDockTap" \
    "FLYME_KEYBOARD_ROUTE_CHANNEL_PREFIX" \
    "FLMKeyboardRouteChannel" \
    "FLMKeyboardRouteChannelName" \
    "FlymeRouteChanged." \
    "fanout=bundle"; do
    reject_source "$marker"
done

for marker in \
    "FLMCenteredCardHeight" \
    "selectedCardHeight / uniformScale" \
    "logicalHeight = cardHeight / uniformScale" \
    "floatingSceneLogicalFrameMatchesVirtualViewport" \
    "FLMVirtualViewportScale" \
    "virtual-viewport-fit" \
    "content-scale policy=card-fit" \
    "content-scale policy=card-1to1" \
    "scene-card commit-request" \
    "scene-card committed" \
    "card-fit=1" \
    "applyFloatingKeyboardViewportAvoidance" \
    "floatingKeyboardViewportApplied" \
    "%hook UIResponder" \
    "%hook NSNotificationCenter" \
    "FLYME_KEYBOARD_FRAME_NOTIFICATION" \
    "FLYME_KEYBOARD_ROUTE_ACK_NOTIFICATION" \
    "additionalSafeAreaInsets" \
    "FLMCorrectKeyboardNotificationUserInfo" \
    "%hook UIWindowScene" \
    "%hook UIKeyboardWindow" \
    "FLMRequestApplicationKeyboardDismiss" \
    "floatingKeyboardRouteReadyGeneration" \
    "route-not-ready" \
    "consumeOutsideTapForKeyboardDismissal" \
    "floatingKeyboardContainerOffsetY" \
    "setFloatingSceneUsesFullscreenKeyboardHost" \
    "widthCompletion" \
    "verticalRevealStart" \
    "widthProgress" \
    "verticalProgress" \
    "fillScale" \
    "setCornerTriggerGesturesEnabled:" \
    "cornerTriggerBounds" \
    "cornerTriggerPointForGesture:" \
    "cornerTriggerPointForTouch:" \
    "scene-virtual-viewport"; do
    reject_source "$marker"
done

for marker in \
    "wrong-target" \
    "centered-close no-op"; do
    reject_source "$marker"
done

for marker in \
    "%hook UITextEffectsWindow" \
    "keyboardScreenReferenceSize" \
    "%hook _UIRemoteKeyboards" \
    "intersectionHeightForWindowScene:" \
    "FLMExternalKeyboardAvoidanceHeight" \
    "FLMDiagnosticEventIntersection" \
    "FLMReadKeyboardSharedState" \
    "FLMPublishKeyboardAppLifecycleStage" \
    "FLMDiagnosticEventAdapterCtor" \
    "FLMDiagnosticEventAdapterReady" \
    "FLMKeyboardLastRouteGeneration" \
    "FLMKeyboardLastGeometryGeneration" \
    "FLMKeyboardLastDismissGeneration" \
    "FLMKeyboardLastProcessedSession" \
    "FLMKeyboardTransportOnceToken" \
    "dispatch_once(&FLMKeyboardTransportOnceToken, ^{" \
    "route-applied" \
    "process-ready-once" \
    "application dismiss-request received count=1" \
    "target-validation result=process-match" \
    "responder-resign begin" \
    "responder-resign end" \
    "scene-fallback-success" \
    "stale-generation" \
    "wrong-process" \
    "FLMApplicationProcessIdentityFlags" \
    "FLMIsExplicitWeChatAdapterProcess" \
    "FLMContentLogicalViewportSize" \
    "FLMPhysicalCardSize" \
    "FLMHandleKeyboardRouteNotification" \
    "FLMHandleKeyboardDismissRequest" \
    "FLMResignTargetApplicationResponder" \
    "FLMSendKeyboardDismissAck" \
    "FLYME_KEYBOARD_DISMISS_REQUEST_NOTIFICATION" \
    "FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION" \
    "sendAction:@selector(resignFirstResponder)" \
    "FLMSceneMatchesKeyboardRoute" \
    "[window endEditing:YES]" \
    "FLMReloadContentViewportSelection" \
    "BOOL shouldApply = NO;" \
    "if (currentHash == FLMKeyboardTargetSceneHash)"; do
    grep -Fq -- "$marker" "$keyboard_source" || {
        echo "missing native keyboard marker: $marker" >&2
        exit 1
    }
done

for marker in \
    "FLMPhysicalReferenceBoundsForScene"; do
    if grep -Fq -- "$marker" "$keyboard_source"; then
        echo "removed keyboard path returned: $marker" >&2
        exit 1
    fi
done

require_source "sb host-update rejected=alternate-host"
require_source "quarantineFloatingKeyboardHost:"
require_source "sb host-quarantine host="
require_source "sb host-quarantine-release host="
require_source "sb host-quarantine-discard host="
require_source "sb host-update quarantined=closing-transaction"
require_source 'reason:@"waiting-pairing"'
require_source 'reason:@"selected-host"'
require_source 'discardAllFloatingKeyboardHostQuarantinesForReason:'
require_source '@"centered-close"'
require_source '@"keyboard-did-hide-active-card"'
require_source '@"keyboard-did-hide-inactive-card"'
require_source 'case FLMDiagnosticEventDidHide: return "did-hide";'

for marker in \
    "floatingKeyboardReopenGuardIdentifier" \
    "sb reopen-keyboard-guard" \
    "stale-keyboard" \
    "FLMFloatingKeyboardReopenObservationDelay" \
    "FLMFloatingKeyboardReopenGuardTimeout"; do
    reject_source "$marker"
done

grep -Fq -- 'host.clipsToBounds = NO' "$source_file"
grep -Fq -- 'centered-preserved=%d' "$source_file"
grep -Fq -- '<key>Bundles</key>' "$keyboard_filter"
grep -Fq -- '<string>com.apple.UIKit</string>' "$keyboard_filter"
grep -Fq -- '<string>com.tencent.xin</string>' "$keyboard_filter"
if grep -Eq '<key>Classes</key>|<key>Executables</key>' "$keyboard_filter"; then
    echo "keyboard filter must use UIKit plus the explicit WeChat target" >&2
    exit 1
fi

source_directory="$(cd "$(dirname "$source_file")" && pwd)"
for removed_file in \
    FMScreenCaptureProvider.h \
    FMScreenCaptureProvider.xm \
    FMScreenSenseSession.h \
    FMScreenSenseSession.xm \
    FMScreenSenseVisionBridge.swift; do
    if [[ -e "$source_directory/$removed_file" ]]; then
        echo "removed ScreenSense source returned: $removed_file" >&2
        exit 1
    fi
done
if grep -Eiq 'FMScreen(Capture|Sense)|VisionKit|IOSurface' "$source_directory/Makefile"; then
    echo "removed ScreenSense build dependency returned" >&2
    exit 1
fi

guard_line="$(grep -nF "addGestureRecognizer:self.cornerGuardGesture" "$source_file" | head -n1 | cut -d: -f1)"
wheel_line="$(grep -nF "addGestureRecognizer:self.cornerGesture];" "$source_file" | head -n1 | cut -d: -f1)"
if [[ -z "$guard_line" || -z "$wheel_line" || "$guard_line" -ge "$wheel_line" ]]; then
    echo "first-frame guard registration order changed" >&2
    exit 1
fi

# A recognizer owned by _UISystemGestureManager may remain in Ended after its
# touch stream drains. The centered-card barrier must therefore follow actual
# active touches and the controller-owned barrier session, never state==Possible.
require_source "BOOL touchesQuiescent ="
require_source "!self.floatingDockBarrierTouchActive"
require_source "touchesQuiescent=1 recognizerState=%ld"
reject_source "floatingDockContentRecognizerReset"

# Dock content stays physically blocked throughout entry/snap/resize settling.
# Once settled, drag the live container at a canonical aspect ratio; a raster
# snapshot or presentation-layer takeover can stretch a remote IOSurface.
require_source "FLMFloatingDockControlTransitionEntry"
require_source "FLMFloatingDockControlTransitionSnap"
require_source "FLMFloatingDockControlTransitionResize"
require_source "lockFloatingDockGeometryForDrag"
require_source "sb dock-drag geometry-locked"
require_source "transport=live-layer"
require_source "transitionTakeover=enabled"
reject_source "transitionTakeover=disabled"
reject_source "FLMKeyboardAccessoryProtectionHeight"
reject_source "floatingKeyboardFrameFallback"
reject_source "floatingDockDragSnapshot"
reject_source "dock-control-takeover"
reject_source "canTakeOverFloatingDockControlAtPoint:"
echo "Stable build 0.9.50 wheel gesture, global keyboard route, fixed Remote Scene presentation scale, outer Dock presentation animation, launch recovery, hidden dock, and card foundation verified"
