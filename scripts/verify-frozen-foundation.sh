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
    "displayCommitted = targetIsFrontmost && attempt >= 1"
    "keyboardPassThroughFrame"
    "floatingKeyboardSessionGeneration"
    "sb frame-apply rejected=inactive-session"
    "sb session-end route-cleared"
    "%hook _UIKeyboardLayerHostView"
)

for marker in "${required_source[@]}"; do
    grep -Fq -- "$marker" "$source_file" || {
        echo "frozen gesture, launch, or keyboard-host marker changed: $marker" >&2
        exit 1
    }
done

required_keyboard=(
    "This module is deliberately a narrow UIKit geometry adapter"
    "%hook UITextEffectsWindow"
    "keyboardScreenReferenceSize"
    "%group FLMRemoteKeyboardGeometry"
    "intersectionHeightForWindowScene:"
    "FLMEndPreviousApplicationKeyboardSession"
    "FLMExternalKeyboardAvoidanceGeneration"
    "notify_register_dispatch(FLYME_KEYBOARD_NOTIFICATION"
)

for marker in "${required_keyboard[@]}"; do
    grep -Fq -- "$marker" "$keyboard_source" || {
        echo "narrow UIKit keyboard adapter changed: $marker" >&2
        exit 1
    }
done

grep -Fq '<key>Bundles</key>' "$keyboard_filter"
grep -Fq '<string>com.apple.UIKit</string>' "$keyboard_filter"
! grep -Fq '<key>Classes</key>' "$keyboard_filter"

removed_keyboard=(
    "%hook UIResponder"
    "%hook NSNotificationCenter"
    "UIKeyboardWillHideNotification"
    "UIKeyboardDidHideNotification"
    "FLYME_KEYBOARD_FRAME_NOTIFICATION"
    "FLYME_KEYBOARD_ROUTE_ACK_NOTIFICATION"
    "FLYME_KEYBOARD_DISMISS_NOTIFICATION"
    "FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION"
    "additionalSafeAreaInsets"
    "FLMCorrectKeyboardNotificationUserInfo"
    "%hook UIWindowScene"
    "%hook UIKeyboardWindow"
    "%hook UIRemoteKeyboardWindow"
)

for marker in "${removed_keyboard[@]}"; do
    if grep -Fq -- "$marker" "$keyboard_source"; then
        echo "obsolete keyboard patch architecture returned: $marker" >&2
        exit 1
    fi
done

removed_source=(
    "FLYME_KEYBOARD_ROUTE_ACK_NOTIFICATION"
    "FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION"
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
