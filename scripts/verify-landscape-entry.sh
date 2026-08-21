#!/usr/bin/env bash
set -euo pipefail

workspace="${1:-.}"
wheel="$workspace/LandscapeWheel.xm"
adapter="$workspace/LandscapeEntryAdapter.xm"
module="$workspace/LandscapeModule.xm"
makefile="$workspace/Makefile"

test -f "$wheel"
test -f "$adapter"
test -f "$module"
test -f "$makefile"

# The horizontal wheel and card lifecycle are independent module objects. The
# failed shared portrait-engine adapter must not return under another name.
grep -Fq '@implementation FLMLandscapeWheelController' "$wheel"
grep -Fq '@implementation FLMLandscapeModule' "$module"
for retired_marker in \
    'FLMLandscapeWheelPresentRootController' \
    'FLMLandscapeModuleSynchronizeRootController' \
    'FLMLandscapeResolveCornerTouch' \
    'landscape-input-rearm' \
    'landscape-root-wheel' \
    'source=portrait-controller' \
    'FLMLandscapeModulePrepareSharedScene' \
    'landscape-bridge-open'; do
    if grep -Fq "$retired_marker" "$wheel" "$adapter" "$module"; then
        echo "failed shared landscape adapter returned: $retired_marker" >&2
        exit 1
    fi
done

# The root FLMWheelController is only the registered gesture owner.  It must
# never be cast to the independent horizontal controller object.
if grep -Fq '(FLMLandscapeWheelController *)sharedController' "$wheel"; then
    echo "unsafe root-to-landscape controller cast detected" >&2
    exit 1
fi

grep -Fq '@property(nonatomic, weak) id rootWheelController;' "$wheel"
grep -Fq 'controller.rootWheelController != rootController' "$wheel"
grep -Fq 'FLMLandscapeSharedGesture(rootController, key)' "$wheel"
grep -Fq '[self restoreSharedPortraitGestureState];' "$wheel"
grep -Fq 'self.guardGesture.enabled = rootEnabled;' "$wheel"

# Landscape reuses the portrait controller's live wheel values and item UI.
# No retired standalone preference domain or wheel-owned launcher may remain.
if grep -Fq 'com.codex.flymelandscape' "$wheel" "$module"; then
    echo "retired standalone landscape preference domain detected" >&2
    exit 1
fi
grep -Fq 'FLMLandscapeSharedValue(portraitController, @"itemIdentifiers")' "$wheel"
grep -Fq 'CFSTR("com.codex.flymemultitasking.preferences-changed")' "$wheel"
grep -Fq 'format:2' "$wheel"
grep -Fq '_iconView.layer.cornerRadius = isLockItem ? 0.0 : size * 0.5;' "$wheel"
if grep -Fq -- '- (void)activateIdentifier:' "$wheel"; then
    echo "landscape wheel must not own application launch" >&2
    exit 1
fi
grep -Fq -- '- (BOOL)prewarmIdentifier:' "$module"

# Opening a card follows the proven portrait route: the target's primary Scene
# is published suspended, then prepareScene: makes that Scene foreground while
# the full-display SpringBoard card remains the key/highest interaction
# boundary. A real Workspace transition is reserved for the explicit white-bar
# right-swipe fullscreen action.
window_body="$(sed -n '/^@implementation FLMLandscapeWindow/,/^@end/p' "$module")"
grep -Fq -- '- (BOOL)canBecomeKeyWindow' <<<"$window_body"
grep -Fq 'return YES;' <<<"$window_body"
grep -Fq -- '- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event' <<<"$window_body"
open_body="$(sed -n '/^- (void)openIdentifier:(NSString \*)identifier {/,/^- (void)lockTimerFired:/p' "$module")"
grep -Fq '[self.window makeKeyAndVisible];' <<<"$open_body"
prewarm_body="$(sed -n '/^- (BOOL)prewarmIdentifier:(NSString \*)identifier {/,/^- (void)scheduleResolveForGeneration:/p' "$module")"
grep -Fq 'suspended:YES' <<<"$prewarm_body"
grep -Fq 'workspaceTransition=0' <<<"$prewarm_body"
if grep -Fq 'suspended:NO' <<<"$prewarm_body" ||
   grep -Fq 'openApplicationWithBundleID:' <<<"$prewarm_body" ||
   grep -Fq 'workspaceTransition=1' <<<"$prewarm_body"; then
    echo "card-open path must not perform a Workspace foreground transition" >&2
    exit 1
fi
grep -Fq 'mode=suspended-prewarm-hosted-portrait' "$module"
grep -Fq 'workspaceOwner=unchanged' "$module"
grep -Fq 'keyboardOwner=system-bridge' "$module"
grep -Fq 'gated=orientation' "$module"
grep -Fq 'action=retry' "$module"

# The application Scene remains a complete portrait 390x844-style canvas.
# Only the Presenter wrapper is uniformly scaled into the landscape card.
grep -Fq 'landscape-scene-handle-stale' "$module"
grep -Fq 'action=reacquire' "$module"
for retired_client_marker in \
    'FLMLandscapeFullScreenContentWidth' \
    'FLMLandscapeFullScreenContentHeight' \
    'FLMLandscapeSceneClientOrientation' \
    'FLMLandscapeConfigureClientOrientation' \
    'full-screen-native-landscape' \
    'CGAffineTransformRotate(presentationTransform, rotation)'; do
    if grep -Fq "$retired_client_marker" "$module"; then
        echo "retired native-landscape content contract returned: $retired_client_marker" >&2
        exit 1
    fi
done
grep -Fq 'FLMLandscapeSceneSettleDelay = 0.04;' "$module"
grep -Fq 'landscape-presenter phase=create-begin' "$module"
grep -Fq 'landscape-presenter recovery' "$module"
grep -Fq 'landscape-host-reveal' "$module"
grep -Fq 'reason=non-portrait-host' "$module"
grep -Fq 'action=wait-portrait-bounds' "$module"
prepare_body="$(sed -n '/^- (BOOL)prepareScene:/,/^- (void)layoutCardAnimated:/p' "$module")"
if [[ "$(grep -Fc '[scene updateSettings:mutableSettings withTransitionContext:nil];' <<<"$prepare_body")" -ne 1 ]]; then
    echo "landscape Scene preparation must use one server-settings transaction" >&2
    exit 1
fi
if grep -Fq 'committedSettings' <<<"$prepare_body"; then
    echo "duplicate landscape Scene settings transaction returned" >&2
    exit 1
fi
grep -Fq 'phase=post-settings-focus-complete' "$module"
grep -Fq 'FLMLandscapePortraitContentWidth = 390.0;' "$module"
grep -Fq 'FLMLandscapePortraitContentHeight = 844.0;' "$module"
grep -Fq 'mode=hosted-portrait-scene visual=uniform-scale' "$module"
grep -Fq 'UIInterfaceOrientation orientation = UIInterfaceOrientationPortrait;' <<<"$prepare_body"
grep -Fq '[mutableSettings setFrame:portraitBounds];' <<<"$prepare_body"
grep -Fq 'hostTransform=identity' "$module"
grep -Fq 'CGAffineTransformMakeScale(uniformScale, uniformScale)' "$module"
grep -Fq '[hostView convertPoint:screenPoint fromView:rootView]' "$module"
grep -Fq 'static const CGFloat FLMLandscapeCardMaximumHeightRatio = 0.92;' "$module"
grep -Fq 'FLMLandscapePortraitCardWidthToHeightRatio' "$module"

# Landscape retains the two already-registered portrait recognizers only as a
# compatibility lease. The full-display window uses local UIKit recognizers so
# backdrop taps, the white-bar swipe, and dock dragging cannot lose ownership.
grep -Fq 'floatingExclusiveGesture' "$module"
grep -Fq 'floatingDockInputGesture' "$module"
grep -Fq 'landscape-card-global-route active' "$module"
grep -Fq 'policy=window-exclusive-local-gestures' "$module"
grep -Fq 'exclusiveBackdropView' "$module"
grep -Fq 'dockInteractionShield' "$module"
grep -Fq 'handleDockPan:' "$module"
grep -Fq 'handleDockTap:' "$module"
grep -Fq 'self.dockPan.enabled = docked;' "$module"
grep -Fq 'self.outsideTap.enabled = interactive' "$module"
grep -Fq 'FLMLandscapeCardOwnsSharedGesture' "$adapter"
grep -Fq 'FLMLandscapeCardShouldReceiveSharedTouch' "$adapter"
grep -Fq 'FLMLandscapeCardShouldBeginSharedGesture' "$adapter"
grep -Fq 'FLMLandscapeCardHandleSharedGesture' "$adapter"
grep -Fq 'handleFloatingExclusiveGesture:' "$adapter"
grep -Fq 'handleFloatingDockInputGesture:' "$adapter"
grep -Fq 'reason=global-outside-tap' "$module"
grep -Fq 'FLMLandscapeInteractionDomainDockCard' "$module"
grep -Fq 'passesTouchesOutsideControls' "$module"

# The state progression mirrors portrait, while landscape adds deterministic
# left/right docking. A released dock card always returns to the fixed top
# margin; an exact horizontal tie resolves to the left. Hidden mode reuses the
# same single white handle and leaves no application sliver.
grep -Fq 'FLMLandscapeDockWidthRatio = 156.0 / 315.0;' "$module"
grep -Fq 'FLMLandscapeDockTopMargin = 15.0;' "$module"
grep -Fq 'transition=expanded-to-docked side=left verticalPolicy=fixed-top' "$module"
grep -Fq 'transition=docked-to-hidden side=left appSliver=0 handle=reused' "$module"
grep -Fq 'transition=collapsed-to-expanded' "$module"
grep -Fq 'hidden-bar-right-swipe' "$module"
grep -Fq 'self.dockedOnRight = cardMidX > displayMidX;' "$module"
grep -Fq 'tiePolicy=left verticalPolicy=fixed-top' "$module"
grep -Fq 'if (self.dockedCard)' "$module"
grep -Fq '[self promoteToFullscreen];' "$module"
grep -Fq 'FLMLandscapeHandleBarLength = 44.0;' "$module"
grep -Fq 'FLMLandscapeHandleGap = 10.0;' "$module"
grep -Fq 'safeArea.top + FLMLandscapeDockTopMargin' "$module"
grep -Fq 'safeArea.left' "$module"
grep -Fq 'usingSpringWithDamping:FLMLandscapeSpringDamping' "$module"
grep -Fq 'self.handlePanInteractive = YES;' "$module"
if [[ "$(grep -Fc 'UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];' "$module")" -ne 1 ]] ||
   [[ "$(grep -Fc '[handle addSubview:bar];' "$module")" -ne 1 ]]; then
    echo "landscape must create exactly one reusable white handle bar" >&2
    exit 1
fi
for retired_interaction_marker in \
    'transition=expanded-to-docked side=physical-left' \
    'transition=docked-to-hidden side=physical-left' \
    'transition=hidden-to-docked' \
    'preservingVerticalCenter' \
    'revealDockedCardAnimated'; do
    if grep -Fq "$retired_interaction_marker" "$module"; then
        echo "retired landscape interaction returned: $retired_interaction_marker" >&2
        exit 1
    fi
done

# Closing must first release the shared protection lease and then genuinely
# deactivate the landscape Scene. Otherwise the next open reuses an active
# landscape client and the card can remain permanently white.
background_body="$(sed -n '/^- (void)backgroundScene:/,/^}/p' "$module")"
grep -Fq 'FLMClearProtectedScene(scene);' <<<"$background_body"
grep -Fq '[scene setForeground:NO];' <<<"$background_body"
grep -Fq '[scene setBackgrounded:YES];' <<<"$background_body"
grep -Fq '[scene deactivate];' <<<"$background_body"
grep -Fq 'landscape-scene-background' <<<"$background_body"

# The bridge reuses iOS' native remote Keyboard Scene; it never draws keyboard
# keys. It must publish the existing FlymeKeyboard route and host the system
# surface in a full-display landscape window.
keyboard_bridge="$workspace/LandscapeKeyboardBridge.xm"
test -f "$keyboard_bridge"
grep -Fq 'FLMLandscapeKeyboardBridgeBegin' "$module"
grep -Fq 'FLMLandscapeKeyboardBridgeEnd' "$module"
grep -Fq 'FLMLandscapeKeyboardBridgeUpdateCard' "$module"
grep -Fq 'com.codex.flymemultitasking.keyboard-state-changed' "$keyboard_bridge"
grep -Fq 'preferredSceneHostIdentity' "$keyboard_bridge"
grep -Fq 'FLMLandscapeKeyboardForwardingWindow' "$keyboard_bridge"
grep -Fq 'UIInterfaceOrientationMaskLandscape' "$keyboard_bridge"
grep -Fq 'method_setImplementation' "$keyboard_bridge"
grep -Fq 'policy=continue-native-host' "$keyboard_bridge"
grep -Fq 'pairingPropagated' "$keyboard_bridge"
grep -Fq 'route=external-full-display cardHost=0' "$keyboard_bridge"
grep -Fq 'policy=external-host-only' "$keyboard_bridge"
grep -Fq 'FLMLandscapeKeyboardBridgeContainsVisualPoint' "$keyboard_bridge"
if grep -Fq 'if (![self applyKeyboardScenePairing' "$keyboard_bridge"; then
    echo "keyboard pairing propagation must not hard-gate native host attachment" >&2
    exit 1
fi
if grep -Eiq 'UIKeyboardLayout|UIKBTree|drawRect:|insertText:' "$keyboard_bridge"; then
    echo "landscape bridge contains a custom keyboard implementation" >&2
    exit 1
fi

# Horizontal sources are part of FlymeMultitasking.dylib in the same deb; a
# separate FlymeLandscape tweak target must never return.
grep -Fq 'LandscapeWheel.xm LandscapeEntryAdapter.xm LandscapeModule.xm' "$makefile"
if grep -Eq '^TWEAK_NAME.*FlymeLandscape([[:space:]]|$)' "$makefile"; then
    echo "standalone FlymeLandscape tweak target detected" >&2
    exit 1
fi

# Only the frozen root controller may register with the private system gesture
# manager.  The horizontal module and its adapter only borrow that family.
registration_files="$(grep -l 'addGestureRecognizer:toDisplayWithIdentity:' "$workspace"/*.xm || true)"
test "$registration_files" = "$workspace/Tweak.xm"

echo "landscape entry ownership verified"
