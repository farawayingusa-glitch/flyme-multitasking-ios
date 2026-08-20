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
# No retired standalone preference domain or duplicate fullscreen launcher may
# remain in the runtime module.
if grep -Fq 'com.codex.flymelandscape' "$wheel" "$module"; then
    echo "retired standalone landscape preference domain detected" >&2
    exit 1
fi
grep -Fq 'FLMLandscapeSharedValue(portraitController, @"itemIdentifiers")' "$wheel"
grep -Fq 'CFSTR("com.codex.flymemultitasking.preferences-changed")' "$wheel"
grep -Fq 'format:2' "$wheel"
grep -Fq '_iconView.layer.cornerRadius = isLockItem ? 0.0 : size * 0.5;' "$wheel"
if grep -Fq -- '- (void)activateIdentifier:' "$wheel" "$module"; then
    echo "duplicate landscape wheel application launcher detected" >&2
    exit 1
fi

# Opening a card must not commit a workspace transition. The SpringBoard card
# is presentation-only and must not compete with the full-screen target Scene
# for key-window or native keyboard ownership.
window_body="$(sed -n '/^@implementation FLMLandscapeWindow/,/^@end/p' "$module")"
grep -Fq -- '- (BOOL)canBecomeKeyWindow' <<<"$window_body"
grep -Fq 'return NO;' <<<"$window_body"
open_body="$(sed -n '/^- (void)openIdentifier:/,/^- (void)lockTimerFired:/p' "$module")"
grep -Fq 'self.window.hidden = NO;' <<<"$open_body"
if grep -Fq '[self.window makeKey' <<<"$open_body" ||
   grep -Fq 'landscape-card-window key-reasserted' "$module"; then
    echo "landscape visual card still takes key-window ownership" >&2
    exit 1
fi
grep -Fq 'inputOwner=application-scene' "$module"
prewarm_body="$(sed -n '/^- (BOOL)prewarmIdentifier:/,/^- (void)scheduleResolveForGeneration:/p' "$module")"
grep -Fq 'suspended:YES' <<<"$prewarm_body"
grep -Fq 'landscape-scene-prewarm' <<<"$prewarm_body"
if grep -Fq 'suspended:NO' <<<"$prewarm_body" ||
   grep -Fq 'openApplicationWithBundleID:' <<<"$prewarm_body"; then
    echo "landscape card startup still promotes the workspace fullscreen" >&2
    exit 1
fi
grep -Fq 'gated=orientation' "$module"
grep -Fq 'action=retry' "$module"

# A foreground launch may replace the app's primary Scene. The horizontal
# module must discard a non-resolving handle and reacquire it. The server Scene
# stays landscape while the suspended launch's portrait client canvas is
# captured before activation. FBScene only permits client parameter mutation
# while inactive; an active Scene must be observation-only.
grep -Fq 'landscape-scene-handle-stale' "$module"
grep -Fq 'action=reacquire' "$module"
grep -Fq 'updateClientSettingsWithBlock:' "$module"
grep -Fq 'configureParameters:' "$module"
grep -Fq 'method=inactive-parameters' "$module"
grep -Fq 'method=active-observation' "$module"
grep -Fq '!activeStateAvailable || sceneActive' "$module"
grep -Fq '!finalActiveStateAvailable || finalSceneActive' "$module"
grep -Fq 'setInterfaceOrientationChangesDisabled:NO' "$module"
if grep -Fq '[scene updateClientSettingsWithBlock:' "$module"; then
    echo "host-side FBScene still uses the application-side live client updater" >&2
    exit 1
fi
initial_client_line="$(grep -n 'phase = @"initial-client-settings"' "$module" | head -n 1 | cut -d: -f1)"
content_state_line="$(grep -n 'phase = @"content-state"' "$module" | head -n 1 | cut -d: -f1)"
test -n "$initial_client_line"
test -n "$content_state_line"
if (( initial_client_line >= content_state_line )); then
    echo "landscape client canvas is no longer captured before activation" >&2
    exit 1
fi
grep -Fq 'FLMLandscapeSceneSettleDelay = 0.04;' "$module"
grep -Fq 'accepted=presenter-fallback' "$module"
grep -Fq 'action=attach-never-white' "$module"
grep -Fq 'landscape-presenter phase=create-begin' "$module"
grep -Fq 'landscape-presenter recovery' "$module"
grep -Fq 'landscape-host-reveal' "$module"
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
grep -Fq 'Never push the client back to portrait after Presenter creation.' "$module"
grep -Fq 'FLMLandscapePortraitCanvasWidth' "$module"
grep -Fq 'visualRotation=0' "$module"
grep -Fq 'static const CGFloat FLMLandscapeCardMaximumHeightRatio = 0.92;' "$module"
grep -Fq 'FLMLandscapePortraitCardWidthToHeightRatio' "$module"
if grep -Fq 'CGAffineTransformRotate' "$module"; then
    echo "landscape card still rotates the application presentation" >&2
    exit 1
fi

# Closing must first release the shared protection lease and then genuinely
# deactivate the landscape Scene. Otherwise the next open reuses an active
# landscape client and the card can remain permanently white.
background_body="$(sed -n '/^- (void)backgroundScene:/,/^}/p' "$module")"
grep -Fq 'FLMClearProtectedScene(scene);' <<<"$background_body"
grep -Fq '[scene setForeground:NO];' <<<"$background_body"
grep -Fq '[scene setBackgrounded:YES];' <<<"$background_body"
grep -Fq '[scene deactivate];' <<<"$background_body"
grep -Fq 'landscape-scene-background' <<<"$background_body"

# Landscape uses the system keyboard owned by the target Scene. A custom
# forwarding session or standalone keyboard host must never return.
for retired_keyboard_marker in \
    'FLMLandscapeKeyboardRoute' \
    'FLMLandscapeKeyboardHost' \
    'keyboardSessionGeneration' \
    'LandscapeKeyboard.xm'; do
    if grep -Fq "$retired_keyboard_marker" "$wheel" "$adapter" "$module" "$makefile"; then
        echo "retired landscape keyboard route returned: $retired_keyboard_marker" >&2
        exit 1
    fi
done

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
