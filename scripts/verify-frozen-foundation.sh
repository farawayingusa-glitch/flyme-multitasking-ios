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
    "FLMPublishKeyboardDismissRequest" \
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
    "floatingDockHideInitialFrame = self.floatingContainer.frame" \
    "if (clearHorizontalIntent)" \
    "finishFloatingDockHiddenGesture" \
    "displayLink.preferredFrameRateRange" \
    "maximumFramesPerSecond" \
    "triggerProgress" \
    "floatingDockFeedbackSent" \
    "updateFloatingFullscreenSnapshotForProgress" \
    "floatingFullscreenProgress" \
    "CGFloat handleWidth = visibleHandleWidth + 40.0;" \
    "keyboardPassThroughFrame"; do
    require_source "$marker"
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

# The portrait freeze must not silently regain any landscape entry point,
# coordinate conversion, or alternate card/Scene layout branch.
for marker in \
    "UIInterfaceOrientationIsLandscape" \
    "UIDeviceOrientationLandscape" \
    "UIInterfaceOrientationMaskAll" \
    "UIDeviceOrientationDidChangeNotification" \
    "orientationDidChange:" \
    "BOOL landscape =" \
    "landscapeWindow" \
    "targetIsLandscape" \
    "referenceIsLandscape"; do
    reject_source "$marker"
done

for marker in \
    "%hook UITextEffectsWindow" \
    "keyboardScreenReferenceSize" \
    "%hook _UIRemoteKeyboards" \
    "intersectionHeightForWindowScene:" \
    "FLMExternalKeyboardAvoidanceHeight" \
    "FLMEndPreviousApplicationKeyboardSession" \
    "FLMDiagnosticEventIntersection" \
    "FLMReadKeyboardSharedState" \
    "FLMPublishKeyboardAppLifecycleStage" \
    "FLMDiagnosticEventAdapterCtor" \
    "FLMDiagnosticEventAdapterReady" \
    "FLMApplicationProcessIdentityFlags" \
    "FLMContentLogicalViewportSize" \
    "FLMPhysicalCardSize" \
    "FLMHandleKeyboardRouteNotification" \
    "FLMHandleKeyboardDismissRequest" \
    "FLMRegisterKeyboardDismissObserverIfNeeded" \
    "FLMReloadContentViewportSelection" \
    "BOOL shouldApply = NO;" \
    "if (currentHash == FLMKeyboardTargetSceneHash)"; do
    grep -Fq -- "$marker" "$keyboard_source" || {
        echo "missing native keyboard marker: $marker" >&2
        exit 1
    }
done

for marker in \
    "UIInterfaceOrientationIsLandscape" \
    "FLMPhysicalReferenceBoundsForScene"; do
    if grep -Fq -- "$marker" "$keyboard_source"; then
        echo "landscape keyboard path returned: $marker" >&2
        exit 1
    fi
done

require_source "sb host-update rejected=alternate-host"

grep -Fq -- 'host.clipsToBounds = NO' "$source_file"
grep -Fq -- 'centered-preserved=%d' "$source_file"
grep -Fq -- '<key>Bundles</key>' "$keyboard_filter"
grep -Fq -- '<string>com.apple.UIKit</string>' "$keyboard_filter"
grep -Fq -- '<string>com.tencent.xin</string>' "$keyboard_filter"
if grep -Eq '<key>Classes</key>|<key>Executables</key>' "$keyboard_filter"; then
    echo "keyboard filter must remain bundle-scoped" >&2
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
echo "Stable build 0.9.53 reset: 0.9.41 portrait foundation, responder cleanup, maximum-refresh Dock rendering, keyboard routing, launch recovery, hidden dock, and card foundation verified"
