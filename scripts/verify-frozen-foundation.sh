#!/usr/bin/env bash
set -euo pipefail

source_file="${1:-Tweak.xm}"

required_lines=(
    "const CGFloat horizontalRadius = 58.0;"
    "const CGFloat verticalRadius = 65.0;"
    "self.cornerGesture.minimumPressDuration = 0.12;"
    "self.cornerGuardGesture.minimumPressDuration = 0.0;"
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
)

for required_line in "${required_lines[@]}"; do
    if ! grep -Fq "$required_line" "$source_file"; then
        echo "frozen 0.3.4 foundation changed: $required_line" >&2
        exit 1
    fi
done

guard_line="$(grep -nF "addGestureRecognizer:self.cornerGuardGesture" "$source_file" |
    head -n1 | cut -d: -f1)"
wheel_line="$(grep -nF "addGestureRecognizer:self.cornerGesture toDisplayWithIdentity:identity" "$source_file" |
    head -n1 | cut -d: -f1)"
if [[ -z "$guard_line" || -z "$wheel_line" || "$guard_line" -ge "$wheel_line" ]]; then
    echo "frozen 0.3.4 first-frame guard registration order changed" >&2
    exit 1
fi

echo "frozen 0.3.4 gesture and wheel foundation verified"
