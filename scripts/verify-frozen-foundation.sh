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

require_keyboard() {
    local marker="$1"
    grep -Fq -- "$marker" "$keyboard_source" || {
        echo "missing Keyboard marker: $marker" >&2
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
    "canReceive && !self.usesSystemGestureManager;" \
    "!self.enabled || self.usesSystemGestureManager;" \
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
    "CAFrameRateRangeMake(maximumRate, maximumRate, maximumRate);" \
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
    "flmFirstRawPoint" \
    "flmLandscapeRawCoordinateMode" \
    "landscapeCornerGuardGesture" \
    "landscapeCornerGesture" \
    "landscapeGlobalCornerGuardGesture" \
    "landscapeGlobalCornerGesture" \
    "resolveLandscapeCornerGesture" \
    "FLMLandscapeRawCoordinateModeFixedLandscapeLeft" \
    "FLMLandscapeRawCoordinateModeFixedLandscapeRight" \
    "FLMLandscapeNotchAvoidanceInset" \
    "presentLandscapeWheelFromRight" \
    "landscapeDirectWheelTaps" \
    "floatingCloseInputArmed" \
    "armFloatingCloseInputForGeneration" \
    "self.floatingCloseInputArmed && !self.floatingWindow.hidden" \
    "landscape-minimal" \
    "self.floatingHandle.hidden = YES;" \
    "self.floatingDockInputGesture.enabled = NO;" \
    "FLMKeyboardSharedContentStrip" \
    "return CGSizeMake(FLMVirtualViewportWidth, FLMVirtualViewportHeight);" \
    "self.cornerGuardGesture.enabled = self.enabled;" \
    "portraitBounds = CGRectMake" \
    "candidateLeft" \
    "candidateRight" \
    "overlayRoot.safeAreaInsets" \
    "hotspotRoot.safeAreaInsets" \
    "beginGeneratingDeviceOrientationNotifications" \
    "displayGeometryDidChange:" \
    "self.landscapeCornerGuardGesture.enabled = self.enabled;" \
    "sb display-geometry-refresh" \
    "sb wheel-should-begin" \
    "landscape-window-opener"; do
    require_source "$marker"
done

require_keyboard "FLMKeyboardContentStrip"



# 0.9.70 introduced the single landscape window space and the machinery that
# 0.9.71 still relies on: the notch-aware safe insets, the visual canvas
# configuration helper, the root-point to visual-point bridge and the landscape
# keyboard frame conversion.
for marker in \
    "FLMPhysicalLandscapeSafeInsets" \
    "FLMConfigureVisualCanvas" \
    "FLMVisualPointFromRootPoint" \
    "floatingPresentationView" \
    "floatingLayoutView" \
    "visualPointForGesture:" \
    "visualPointForTouch:" \
    "physicalSafe={" \
    "overlayRoot=%@" \
    "FLMSpringBoardWindowBounds" \
    "self.overlayWindow.frame = wheelWindowBounds" \
    "self.cornerGesture.enabled = self.enabled;" \
    "FLMLandscapeNotchAvoidanceInset" \
    "presentLandscapeWheelFromRight" \
    "floatingCloseInputArmed" \
    "floatingCloseArmAt" \
    "sb wheel-pinned selectionRoute=%@" \
    "sb wheel-window-select" \
    "landscapeWheelLocalPointFromVisualPoint" \
    "landscapeWheelVisualCenters" \
    "synchronizeLandscapeWheelItemCenters" \
    "sb landscape-wheel-space sceneOrientation=%ld" \
    "landscapeVisualKeyboardBandForScreenFrame" \
    "FLMVisualRectFromRootRect" \
    "FLMVisualPointFromRootPoint" \
    "landscapeKeyboardInteractionFrame" \
    "floatingLandscapeKeyboardTouchBand" \
    "FLMBoundsAreLandscape(visualBounds) &&" \
    "setFloatingKeyboardPreferredHostIdentity" \
    "route=mutable-settings" \
    "convertedFrame=%@" \
    "self.floatingWindow.frame = wheelWindowBounds" \
    "self.floatingWindow.frame = settledWheelWindowBounds"; do
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

# 0.9.71 withdraws the 0.9.70 physical window space. Windows and their root
# views are back at the SpringBoard scene bounds so the rotated presentation
# canvas branch can actually fire again; the canvas measures where its own
# origin lands in screen space and flips the rotation sign when it lands on the
# far corner. The wheel is laid out by a geometry solver that insets both sides
# by the notch and scans for the largest radius whose arc still satisfies the
# minimum icon pitch. The keyboard forwarding window is back at the scene
# bounds with a rotated canvas and hit-tests in physical display space.
for marker in \
    "FLMCanvasScreenSpace" \
    "FLMCanvasOriginLandedOnFarCorner" \
    "FLMLogCanvasVerification" \
    "sb canvas-verify canvas=%@" \
    "FLMWheelMaximumRings" \
    "FLMWheelSpanMaximum" \
    "FLMWheelAnglePitch" \
    "FLMWheelSpanNeeded" \
    "FLMWheelResolveRadius" \
    "FLMWheelRingSpan" \
    "FLMWheelHorizontalAngle" \
    "FLMWheelResolvePlan" \
    "FLMWheelRingPoint" \
    "sb landscape-wheel-rings" \
    "FLMConfigureVisualCanvas(self.wheelContainer, overlayRoot," \
    "FLMConfigureVisualCanvas(self.floatingPresentationView," \
    "FLMConfigureVisualCanvas(rootView, window, visualBounds, orientation);" \
    "floatingSessionVisualBounds" \
    "configureKeyboardForwardingWindowGeometry:" \
    "sb kbd-discover" \
    "sb kbd-pair-attempt" \
    "sb kbd-hide-cause" \
    "Display Space Unification 0.9.74" \
    "CGRect wheelWindowBounds = windowBounds;" \
    "self.floatingWindow.frame = wheelWindowBounds"; do
    require_source "$marker"
done
require_keyboard "route-reload targetHash=%llu"
require_keyboard "FLMDiagnosticEventRouteTuple"

# 0.9.72 fixes the real root cause the 0.9.71 capture exposed. SpringBoard's
# window scene stays portrait while the physical display is landscape and the
# system rotates the scene onto the panel, so a window sized from the physical
# bounds covers only part of the panel and never enters the rotate branch. The
# window must use the scene size, i.e. the transposed physical bounds.
for marker in \
    "FLMBoundsAreLandscape(screenBounds)" \
    "return CGRectMake(0.0, 0.0, height, width);" \
    "FLMLogUnrotatedLandscapeCanvas" \
    "sb canvas-anomaly root=%@ visual=%@ reason=root-not-portrait" \
    "Display Space Unification 0.9.74"; do
    require_source "$marker"
done

# 0.9.73 measures the landscape housing per side and spends the whole feasible
# quadrant, so the icons land on the summoned physical edge and on the bottom
# edge instead of stopping 51pt short of a clean edge. It also re-applies the
# rotated canvas once the overlay window is actually visible, because the
# first-summon self-correction reads UIScreen.coordinateSpace while hidden.
for marker in     "housingInsetLeft"     "housingInsetRight"     "housingOnLeft"     "FLMDiagnosticEventRouteTuple: return \"route-tuple\";"     "Display Space Unification 0.9.74"; do
    require_source "$marker"
done

# 0.9.74 replaces the orientation-guessed point conversion with the identity the
# composition of the system scene rotation and the canvas rotation actually
# produces, so Scene-space frames land on the display in the right place. The
# keyboard is a band against the physical wall rather than a portrait strip,
# the canvas sign is judged from its display bounding box instead of a corner
# distance that also matched a stale portrait layout, and the card stands beside
# a visible keyboard band.
for marker in \
    "FLMVisualPointFromRootPoint" \
    "FLMVisualRectFromRootRect" \
    "landscapeVisualKeyboardBandForScreenFrame" \
    "landscapeKeyboardInteractionFrame" \
    "floatingLandscapeKeyboardTouchBand" \
    "landscapeKeyboardStripOriginForBandWidth" \
    "floatingLandscapeCanvasOrientation" \
    "CGRect canvasInScreen = [canvas convertRect:canvas.bounds" \
    "return CGRectGetWidth(canvasInScreen) + 2.0 <" \
    "visualWidth / 2.0 + dy" \
    "visualHeight / 2.0 - dx"; do
    require_source "$marker"
done

reject_source "FLMKeyboardSharedCacheRevision"
reject_source "FLMOverlayWindowBounds"
reject_source "itemCountsByRingForCount:"

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
echo "Display Space Unification 0.9.74: transposed window bounds, self-correcting rotated canvas, notch-aware wheel solver, keyboard space verified"
