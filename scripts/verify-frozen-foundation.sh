#!/usr/bin/env bash
set -euo pipefail

source_file="${1:-Tweak.xm}"
keyboard_source="${2:-Keyboard.xm}"

required_lines=(
    "const CGFloat horizontalRadius = 58.0;"
    "const CGFloat verticalRadius = 65.0;"
    "self.cornerGesture.minimumPressDuration = 0.12;"
    "self.cornerGuardGesture.minimumPressDuration = 0.0;"
    "CGPoint rawPoint = [touch locationInView:nil];"
    "CGPoint rawPoint = [gesture locationInView:nil];"
    "CGPoint point = FLMVisualPointFromRawPoint(rawPoint);"
    "return totalMovement >= 14.0 &&"
    "(inwardMovement >= 4.0 || upwardMovement >= 4.0);"
    "static const CGFloat FLMDefaultWheelRadius = 202.0;"
    "static const CGFloat FLMDefaultWheelIconSize = 56.0;"
    "maximumDistance:self.wheelIconSize * 0.5 + 2.0"
    "CGFloat firstRadius = MIN(self.wheelRadius, maximumRadius);"
    "CGFloat desiredSpacing = self.wheelIconSize + 20.0;"
    "CGFloat containerWidth = width * 0.77;"
    "CGFloat containerHeight = 520.0;"
    "floor((height - containerHeight) * 0.5 - 44.0);"
    "CGRectMake(0.0, 0.0, 5.0, handleHeight);"
    "updateFloatingFullscreenSnapshotForProgress"
    "wrapper.frame = frame;"
    "displayCommitted = targetIsFrontmost && attempt >= 1"
    "CGAffineTransformMakeScale(scale, scale)"
    "setFloatingApplicationInputBlocked:YES"
    "CGFloat handleWidth = visibleHandleWidth + 40.0;"
    "self.floatingDockWidth = FLMMinimumDockWidth;"
    "updateFloatingDockAccessoryPositions"
    "keyboardPassThroughFrame"
    "FLMPublishKeyboardState(identifier, nil);"
)

for required_line in "${required_lines[@]}"; do
    if ! grep -Fq "$required_line" "$source_file"; then
        echo "frozen 0.3.4 foundation changed: $required_line" >&2
        exit 1
    fi
done

if grep -Fq "locationInView:self.overlayWindow.rootViewController.view" "$source_file"; then
    echo "global wheel touch was incorrectly converted through the overlay window" >&2
    exit 1
fi

if grep -Fq 'CFPreferencesSetValue(CFSTR("DockWidth")' "$source_file"; then
    echo "docked card size persistence was reintroduced" >&2
    exit 1
fi

if grep -Eq 'systemHome|SystemHome|SBHomeGesture' "$source_file"; then
    echo "removed system-bottom handoff code was reintroduced" >&2
    exit 1
fi

if grep -Fq '%hook UIRemoteKeyboardWindow' "$source_file" ||
   grep -Fq '%hook UIKeyboardWindow' "$source_file"; then
    echo "SpringBoard runtime directly hooks keyboard windows" >&2
    exit 1
fi

for keyboard_line in \
    '%hook UITextEffectsWindow' \
    'keyboardScreenReferenceSize' \
    'FLMIdentifierHash' \
    'FLMSceneMatchesKeyboardRoute' \
    'FLYME_KEYBOARD_SCENE_NOTIFICATION' \
    'FLYME_KEYBOARD_PREPARE_NOTIFICATION' \
    'FLMKeyboardPrepareDebounce = 0.15' \
    'UIKeyboardWillHideNotification' \
    '- (BOOL)resignFirstResponder' \
    '%hook UIResponder' \
    'notify_register_dispatch(FLYME_KEYBOARD_NOTIFICATION'; do
    if ! grep -Fq "$keyboard_line" "$keyboard_source"; then
        echo "safe keyboard bridge changed: $keyboard_line" >&2
        exit 1
    fi
done

for overlay_line in \
    '@interface FLMKeyboardOverlayWindow' \
    'keyboardLayerHostView:' \
    'valueForKey:@"_owningScene"' \
    'floatingKeyboardOriginalSuperview' \
    'requestFloatingKeyboardHostPreparation' \
    'floatingReusableKeyboardLayerHostView' \
    'const CGFloat widthCompletion = 0.82;' \
    'const CGFloat verticalRevealStart = 0.22;' \
    'background.alpha = verticalProgress > 0.0001 ? 1.0 : 0.0;' \
    '[UIView performWithoutAnimation:^{'; do
    if ! grep -Fq "$overlay_line" "$source_file"; then
        echo "keyboard overlay or continuous fullscreen morph changed: $overlay_line" >&2
        exit 1
    fi
done

if grep -Fq 'setFloatingSceneUsesFullscreenKeyboardHost' "$source_file"; then
    echo "whole application Scene keyboard expansion was reintroduced" >&2
    exit 1
fi

for unsafe_keyboard_line in \
    '%hook _UIRemoteKeyboards' \
    '- (void)didMoveToWindow' \
    'FLMKeyboardPreparePosted'; do
    if grep -Fq -- "$unsafe_keyboard_line" "$source_file" ||
       grep -Fq -- "$unsafe_keyboard_line" "$keyboard_source"; then
        echo "unsafe or one-shot keyboard path detected: $unsafe_keyboard_line" >&2
        exit 1
    fi
done

if grep -Fq '%hook UIWindowScene' "$keyboard_source"; then
    echo "application Scene reference bounds are being overridden again" >&2
    exit 1
fi

if grep -Eq '^%hook UIWindow[[:space:]]*$' "$keyboard_source"; then
    echo "keyboard bridge grew beyond the verified minimal hook surface" >&2
    exit 1
fi

guard_line="$(grep -nF "addGestureRecognizer:self.cornerGuardGesture" "$source_file" |
    head -n1 | cut -d: -f1)"
wheel_line="$(grep -nF "addGestureRecognizer:self.cornerGesture toDisplayWithIdentity:identity" "$source_file" |
    head -n1 | cut -d: -f1)"
if [[ -z "$guard_line" || -z "$wheel_line" || "$guard_line" -ge "$wheel_line" ]]; then
    echo "frozen 0.3.4 first-frame guard registration order changed" >&2
    exit 1
fi

echo "frozen 0.3.4 gesture and wheel foundation verified"
