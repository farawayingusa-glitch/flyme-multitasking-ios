#!/usr/bin/env bash
set -euo pipefail

source_file="${1:-Tweak.xm}"

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
    "displayCommitted = targetIsFrontmost && attempt >= 1"
    "keyboardPassThroughFrame"
    "floatingKeyboardSessionGeneration"
    "sb frame-apply rejected=inactive-session"
    "sb session-end route-cleared"
    "%hook _UIKeyboardLayerHostView"
    "updateClientSettingsWithBlock:"
    "setPreferredSceneHostIdentity:"
    "sb scene-pair apply="
    "sb scene-pair clear="
    "sb viewport committed"
)

for marker in "${required_source[@]}"; do
    grep -Fq -- "$marker" "$source_file" || {
        echo "frozen gesture, launch, or keyboard-host marker changed: $marker" >&2
        exit 1
    }
done

removed_source=(
    "FLMPublishKeyboardState"
    "FLMPublishKeyboardAvoidance"
    "FLMPublishKeyboardCardGeometry"
    "FLYME_KEYBOARD_NOTIFICATION"
    "FLYME_KEYBOARD_SESSION_NOTIFICATION"
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
)

for marker in "${removed_source[@]}"; do
    if grep -Fq -- "$marker" "$source_file"; then
        echo "obsolete SpringBoard keyboard gate returned: $marker" >&2
        exit 1
    fi
done

guard_line="$(grep -nF "addGestureRecognizer:self.cornerGuardGesture" "$source_file" | head -n1 | cut -d: -f1)"
wheel_line="$(grep -nF "addGestureRecognizer:self.cornerGesture toDisplayWithIdentity:identity" "$source_file" | head -n1 | cut -d: -f1)"
if [[ -z "$guard_line" || -z "$wheel_line" || "$guard_line" -ge "$wheel_line" ]]; then
    echo "frozen first-frame guard registration order changed" >&2
    exit 1
fi

echo "frozen gesture foundation and SpringBoard-owned keyboard architecture verified"
