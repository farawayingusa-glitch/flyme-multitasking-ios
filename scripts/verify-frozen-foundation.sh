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
    "self.hotspotWindow.hidden = !self.enabled || !needsWindowIngress;" \
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
    "CGAffineTransformMakeScale(hostScale, hostScale)" \
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
    "ensureFloatingDockInputDisplayLink" \
    "beginFloatingHighRefreshLeaseForDuration" \
    "minimumRate = maximumRate >= 120.0f ? 80.0f : maximumRate;" \
    "CGRect handoffFrame" \
    "bringSubviewToFront:self.floatingHandle" \
    "floatingDockControlArmed" \
    "FLMPublishDockInputBlockState" \
    "FLMDockInputBlockState" \
    "FLYME_DOCK_INPUT_BLOCK_NOTIFICATION" \
    "BOOL remoteInputBlocked = docked || hidden || contentProtected;" \
    "dock-input-block publish" \
    "schema=19" \
    "springboard-ctor-reset" \
    "dock-control-armed" \
    "dock-entry-control-handoff" \
    "floatingDockHiddenFractionForFrame" \
    "self.floatingHandleBar.alpha = hiddenFraction;" \
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
    "scene-virtual-viewport" \
    "blocksFloatingContentInput" \
    "floatingContentInputShieldView" \
    "card-control-block" \
    "BOOL prewarmForFloatingSession"; do
    reject_source "$marker"
done

# 0.9.59 keeps the portrait foundation above but intentionally adds a
# separate landscape contract. Require its locked geometry/presentation path.
for marker in \
    "FLMBoundsAreLandscape" \
    "FLMLandscapeOrientationForSafeInsets" \
    "captureFloatingOrientationContract" \
    "clearFloatingOrientationContract" \
    "landscapeFloatingFrame" \
    "FLMLandscapeHandleVisibleLength" \
    "sb wheel-landscape-layout" \
    "sb presentation-session landscape=" \
    "sb landscape-scene-contract" \
    "sb landscape-handle dock-armed" \
    "landscape-portrait-strip" \
    "currentMidX > screenMidX" \
    "!FLMDisplayIsLandscape()" \
    "UIInterfaceOrientationMaskAll"; do
    require_source "$marker"
done

# 0.9.59 repairs the first landscape entry without weakening the proven
# portrait route. The private system manager remains registered, while a
# landscape-only SpringBoard hotspot and recognizer-owned touch origin provide
# deterministic fallback when shouldReceiveTouch: is skipped after rotation.
for marker in \
    "flmFirstTouchPoint" \
    "flmHasFirstTouchPoint" \
    "landscapeCornerGuardGesture" \
    "landscapeCornerGesture" \
    "beginGeneratingDeviceOrientationNotifications" \
    "displayGeometryDidChange:" \
    "needsWindowIngress = landscape || !self.usesSystemGestureManager" \
    "sb display-geometry-refresh" \
    "sb wheel-should-begin" \
    "landscape-window-opener"; do
    require_source "$marker"
done



# 0.9.60 repairs the SpringBoard presentation-coordinate split observed in
# Diagnostic(37): the physical display can be 844x390 while SpringBoard's root
# view remains 390x844. Require a rotated child canvas, physical safe-area
# normalization, and explicit touch conversion instead of forcing root geometry.
for marker in \
    "FLMPhysicalLandscapeSafeInsets" \
    "FLMConfigureVisualCanvas" \
    "FLMVisualPointFromRootPoint" \
    "floatingPresentationView" \
    "floatingLayoutView" \
    "visualPointForGesture:" \
    "visualPointForTouch:" \
    "physicalSafe={" \
    "overlayRoot=%@"; do
    require_source "$marker"
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
    "%group FLMDockInputBarrier" \
    "%hook UIApplication" \
    "sendEvent:(UIEvent *)event" \
    "FLMDockInputBlockedForCurrentApplication" \
    "FLMCurrentApplicationIdentifierHash" \
    "FLMShouldSuppressDockTouchEvent" \
    "FLMDockInputSuppressedTouches" \
    "FLMInstallDockInputBarrierIfEligible" \
    "FLMDockInputBarrierRetryScheduled" \
    "FLMDiagnosticEventInputSuppressed" \
    "FLYME_DOCK_INPUT_BLOCK_NOTIFICATION" \
    "BOOL shouldApply = FLMKeyboardTargetApplication &&" \
    "if (currentHash == FLMKeyboardTargetSceneHash)"; do
    grep -Fq -- "$marker" "$keyboard_source" || {
        echo "missing native keyboard marker: $marker" >&2
        exit 1
    }
done

for marker in \
    "FLYME_KEYBOARD_SHARED_STATE_VERSION 3" \
    "FLMKeyboardLandscapeScene" \
    "FLMKeyboardSystemReferenceSize" \
    "FLMContentExternalScale = systemHeight / fallback.height;" \
    "landscape-content-strip" \
    "portraitStripScale"; do
    grep -Fq -- "$marker" "$keyboard_source" || {
        echo "missing landscape keyboard marker: $marker" >&2
        exit 1
    }
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
landscape_guard_line="$(grep -nF "addGestureRecognizer:self.landscapeCornerGuardGesture" "$source_file" | head -n1 | cut -d: -f1)"
landscape_wheel_line="$(grep -nF "addGestureRecognizer:self.landscapeCornerGesture" "$source_file" | head -n1 | cut -d: -f1)"
if [[ -z "$landscape_guard_line" || -z "$landscape_wheel_line" || "$landscape_guard_line" -ge "$landscape_wheel_line" ]]; then
    echo "landscape fallback guard registration order changed" >&2
    exit 1
fi
echo "0.9.60 landscape experimental: frozen 0.9.57 portrait foundation plus landscape Scene/content/keyboard contracts, dual-route wheel ingress, and physical presentation coordinates verified"
