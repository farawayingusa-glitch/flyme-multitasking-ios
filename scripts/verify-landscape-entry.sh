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

# Opening a card must not commit a workspace transition. Match the frozen
# portrait lifecycle: make the SpringBoard host key, prewarm suspended, then
# foreground the resolved full-display Scene through FrontBoard settings.
grep -Fq '[self.window makeKeyAndVisible];' "$module"
grep -Fq '@property(nonatomic, weak) UIWindow *previousKeyWindow;' "$module"
grep -Fq '[previousKeyWindow makeKeyWindow];' "$module"
grep -Fq 'landscape-card-window key-reasserted' "$module"
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
# stays landscape while client settings establish an upright portrait canvas.
grep -Fq 'landscape-scene-handle-stale' "$module"
grep -Fq 'action=reacquire' "$module"
grep -Fq 'updateClientSettingsWithBlock:' "$module"
if grep -Fq 'configureParameters:' "$module"; then
    echo "activated landscape Scene still uses creation-only parameters" >&2
    exit 1
fi
grep -Fq 'method=live-update' "$module"
grep -Fq 'FLMLandscapeSceneSettleDelay = 0.10;' "$module"
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
grep -Fq 'FLMLandscapePortraitCanvasWidth' "$module"
grep -Fq 'visualRotation=0' "$module"
grep -Fq 'static const CGFloat FLMLandscapeCardMaximumHeightRatio = 0.92;' "$module"
grep -Fq 'FLMLandscapePortraitCardWidthToHeightRatio' "$module"
if grep -Fq 'CGAffineTransformRotate' "$module"; then
    echo "landscape card still rotates the application presentation" >&2
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
