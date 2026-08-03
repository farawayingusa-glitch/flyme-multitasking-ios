#!/usr/bin/env bash
set -euo pipefail

source_file="${1:-Tweak.xm}"
keyboard_source="${2:-Keyboard.xm}"
keyboard_filter="${3:-FlymeKeyboard.plist}"

required_source=(
    "const CGFloat horizontalRadius = 58.0;"
    "const CGFloat verticalRadius = 65.0;"
    "self.cornerGesture.minimumPressDuration = 0.12;"
    "self.cornerGuardGesture.minimumPressDuration = 0.0;"
    "CGPoint rawPoint = [touch locationInView:nil];"
    "CGPoint rawPoint = [gesture locationInView:nil];"
    "return totalMovement >= 14.0 &&"
    "static const CGFloat FLMDefaultWheelRadius = 202.0;"
    "static const CGFloat FLMDefaultWheelIconSize = 56.0;"
    "CGFloat handleWidth = visibleHandleWidth + 40.0;"
    "updateFloatingFullscreenSnapshotForProgress"
    "floatingFullscreenProgress"
    "scene-frame policy=fullscreen"
    "content-scale policy=%@ systemSceneReference="
    "contentViewportReference="
    "sceneFrameReference=system"
    "floatingSystemSceneReferenceSize"
    "floatingContentViewportReferenceSize"
    "floatingSceneUsesCardGeometry"
    "floatingSceneCardGeometryPending"
    "floatingSceneCardGeometryCommitted"
    "floatingSceneLogicalFrameMatchesSystemReference"
    "content-viewport request"
    "content-viewport committed"
    "content-viewport-fit"
    "FLMVirtualViewportHeight"
    "floatingKeyboardFramePending"
    "frame-deferred waiting=scene-host"
    "host-deferred waiting=application-host"
    "frame-deferred replay=1"
    "content-viewport-restore"
    "floatingCloseInProgress"
    "finishFloatingCloseWithToken:"
    "floatingQueuedIdentifier"
    "sb centered-close cleanup-once"
    "sb presenter-stale-retry"
    "FLMVirtualViewportWidth = 390.0"
    "FLMVirtualViewportScale = 0.77"
    "FLMVirtualViewportHeight = 675.3246753246753"
    "floatingHostReferenceSize"
    "applyFloatingSceneLogicalFrameForCurrentPresentation"
    "geometryProgress"
    "displayCommitted = targetIsFrontmost && attempt >= 1"
    "fullscreen-handoff"
    "restoring-card=1"
    "keyboardPassThroughFrame"
    "floatingKeyboardSessionGeneration"
    "sb frame-apply rejected=inactive-session"
    "sb session-end route-cleared"
    "%hook _UIKeyboardLayerHostView"
    "updateClientSettingsWithBlock:"
    "setPreferredSceneHostIdentity:"
    "sb scene-pair apply="
    "sb scene-pair clear="
    "FLMPublishKeyboardState"
    "FLMPublishKeyboardAvoidance"
    "FLMPublishKeyboardCardGeometry"
    "FLMScheduleKeyboardSharedStateWrite"
    "FLMKeyboardAppAdapterReadyForIdentifier"
)

for marker in "${required_source[@]}"; do
    grep -Fq -- "$marker" "$source_file" || {
        echo "frozen gesture, launch, or keyboard-host marker changed: $marker" >&2
        exit 1
    }
done

removed_source=(
    "applyFloatingKeyboardViewportAvoidance"
    "floatingKeyboardViewportApplied"
    "sb viewport committed"
    "%hook UIResponder"
    "%hook NSNotificationCenter"
    "FLYME_KEYBOARD_FRAME_NOTIFICATION"
    "FLYME_KEYBOARD_ROUTE_ACK_NOTIFICATION"
    "FLYME_KEYBOARD_DISMISS_NOTIFICATION"
    "FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION"
    "additionalSafeAreaInsets"
    "FLMCorrectKeyboardNotificationUserInfo"
    "%hook UIWindowScene"
    "%hook UIKeyboardWindow"
    "FLMRequestApplicationKeyboardDismiss"
    "floatingKeyboardRouteReadyGeneration"
    "route-not-ready"
    "consumeOutsideTapForKeyboardDismissal"
    "floatingKeyboardContainerOffsetY"
    "setFloatingSceneUsesFullscreenKeyboardHost"
    "widthCompletion"
    "verticalRevealStart"
    "widthProgress"
    "verticalProgress"
    "fillScale"
    "scene-virtual-viewport"
    "floatingSceneLogicalFrameMatchesVirtualViewport"
    "virtual-viewport-fit"
    "virtual-viewport restore keyboard-session-restored"
    "content-scale policy=card-fit"
    "content-scale policy=card-1to1"
    "scene-card commit-request"
    "scene-card committed"
    "card-fit=1"
)

for marker in "${removed_source[@]}"; do
    if grep -Fq -- "$marker" "$source_file"; then
        echo "obsolete SpringBoard keyboard gate returned: $marker" >&2
        exit 1
    fi
done

required_keyboard_source=(
    "%hook UITextEffectsWindow"
    "keyboardScreenReferenceSize"
    "%hook _UIRemoteKeyboards"
    "intersectionHeightForWindowScene:"
    "FLMExternalKeyboardAvoidanceHeight"
    "FLMEndPreviousApplicationKeyboardSession"
    "FLMDiagnosticEventIntersection"
    "FLMReadKeyboardSharedState"
    "FLMPublishKeyboardAppLifecycleStage"
    "FLMDiagnosticEventAdapterCtor"
    "FLMDiagnosticEventAdapterReady"
    "FLMApplicationProcessIdentityFlags"
    "FLMContentLogicalViewportSize"
    "FLMContentExternalScale = 0.77"
    "FLMContentViewportAdapter"
    "FLMHandleKeyboardRouteNotification"
)

grep -Fq -- 'host.clipsToBounds = NO' "$source_file"
grep -Fq -- 'centered-preserved=%d' "$source_file"

for marker in "${required_keyboard_source[@]}"; do
    grep -Fq -- "$marker" "$keyboard_source" || {
        echo "native application keyboard marker missing: $marker" >&2
        exit 1
    }
done

grep -Fq -- '<key>Bundles</key>' "$keyboard_filter"
grep -Fq -- '<string>com.apple.UIKit</string>' "$keyboard_filter"
if grep -Eq 'com.tencent.xin|<key>Classes</key>|<key>Executables</key>' "$keyboard_filter"; then
    echo "keyboard adapter filter must use generic UIKit injection with in-process target gating" >&2
    exit 1
fi

guard_line="$(grep -nF "addGestureRecognizer:self.cornerGuardGesture" "$source_file" | head -n1 | cut -d: -f1)"
wheel_line="$(grep -nF "addGestureRecognizer:self.cornerGesture toDisplayWithIdentity:identity" "$source_file" | head -n1 | cut -d: -f1)"
if [[ -z "$guard_line" || -z "$wheel_line" || "$guard_line" -ge "$wheel_line" ]]; then
    echo "frozen first-frame guard registration order changed" >&2
    exit 1
fi

echo "frozen gesture foundation, 390x675.324675 logical viewport at 0.77 to 300.3x520, generic keyboard route, and serialized close verified"
