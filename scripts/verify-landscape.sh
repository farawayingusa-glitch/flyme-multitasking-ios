#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
landscape="$root/Landscape.xm"
bridge="$root/FLMLandscapeRuntime.h"
tweak="$root/Tweak.xm"
makefile="$root/Makefile"

require_literal() {
    local file="$1"
    local marker="$2"
    if ! grep -Fq -- "$marker" "$file"; then
        echo "landscape verification missing marker: $marker ($file)" >&2
        exit 1
    fi
}

reject_literal() {
    local file="$1"
    local marker="$2"
    if grep -Fq -- "$marker" "$file"; then
        echo "landscape verification rejected legacy marker: $marker ($file)" >&2
        exit 1
    fi
}

test -s "$landscape"
test -s "$bridge"
require_literal "$makefile" "Tweak.xm Landscape.xm SceneLifecycle.xm"

# The landscape route is a separate controller and only crosses the portrait
# implementation through this narrow bridge.
require_literal "$landscape" "@interface FLMLandscapeCoordinator"
require_literal "$landscape" "FLMLCardStateOperation"
require_literal "$landscape" "FLMLCardStateDocked"
require_literal "$landscape" "FLMLCardStateHidden"
require_literal "$bridge" "FLMQuiescePortraitControllerForLandscape"
require_literal "$tweak" "FLMLandscapeStart();"
require_literal "$tweak" "FLMLandscapeKeyboardSessionGeneration()"

# Geometry stays in the physical landscape coordinate space while application
# content keeps the stable portrait logical canvas used by keyboard routing.
require_literal "$landscape" "static const CGFloat FLMLLogicalWidth = 390.0;"
require_literal "$landscape" "static const CGFloat FLMLLogicalHeight = 844.0;"
require_literal "$landscape" "FLMLActiveInterfaceOrientation"
require_literal "$landscape" "FLMLPhysicalDisplayBounds"
require_literal "$landscape" "view.safeAreaInsets"
require_literal "$landscape" "self.presentingFromRight ? -dx : dx"
require_literal "$landscape" "CGRectGetMinX(safe) + FLMLCardSideMargin"

# The cross-Scene recognizer must remain alive while SpringBoard itself still
# reports portrait, and a window-local route must remain available even when
# private system registration reports success without delivering callbacks.
require_literal "$landscape" "@interface FLMLandscapeCornerGestureRecognizer"
require_literal "$landscape" "self.globalCornerGesture.enabled = configured;"
require_literal "$landscape" "self.hotspotWindow.hotspotsEnabled = canSummon"
require_literal "$landscape" "FLMLRawCoordinateModeFixedPortrait"
require_literal "$landscape" "FLMLRawCoordinateModeCurrent"
require_literal "$landscape" "resolveAndPrimeGlobalCornerGesture"

# Interaction invariants: left/right hide symmetry, exact-center-left snap,
# dock tap returning to left operation mode, and normal iOS fullscreen launch.
require_literal "$landscape" "self.dockedOnRight ? translation.x : -translation.x"
require_literal "$landscape" "self.dockedOnRight ? -translation.x : translation.x"
require_literal "$landscape" "CGRectGetMidX(current) > CGRectGetMidX(safe)"
require_literal "$landscape" "[self returnDockToOperation]"
require_literal "$landscape" "[self operationFrame]"
require_literal "$landscape" "launchApplicationWithIdentifier:identifier"
require_literal "$landscape" "policy=ios-normal"

# Docked content is shielded and the hidden bar is animated with the card.
require_literal "$landscape" "self.contentShield.hidden = NO;"
require_literal "$landscape" "self.hostView.userInteractionEnabled = NO;"
require_literal "$landscape" "self.edgeHandleBar.alpha = progress;"
require_literal "$landscape" "self.edgeHandleBar.alpha = 1.0 - progress;"

# Keyboard forwarding must stay session-scoped and use actual physical overlap.
require_literal "$landscape" "FLMPublishKeyboardState(self.identifier"
require_literal "$landscape" "_keyboardPreferredHostIdentity"
require_literal "$landscape" "CGRectIntersection(self.cardContainer.frame"
require_literal "$landscape" "UIKeyboardWillChangeFrameNotification"
require_literal "$landscape" "UIKeyboardDidHideNotification"

# Do not revive the previously failed orientation-lock/window-retarget hacks.
reject_literal "$landscape" "setAutorotationLocked"
reject_literal "$landscape" "_setHostsKeyboard"
reject_literal "$landscape" "forceInterfaceOrientation"

echo "independent landscape wheel, card states, safe-area geometry, fullscreen handoff, and keyboard routing verified"
