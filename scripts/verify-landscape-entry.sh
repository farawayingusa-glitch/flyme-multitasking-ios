#!/usr/bin/env bash
set -euo pipefail

workspace="${1:-.}"
wheel="$workspace/LandscapeWheel.xm"
adapter="$workspace/LandscapeEntryAdapter.xm"
module="$workspace/LandscapeModule.xm"
header="$workspace/FLMLandscapeModule.h"
makefile="$workspace/Makefile"

for file in "$wheel" "$adapter" "$module" "$header" "$makefile"; do
    test -f "$file"
done

# Landscape must be an adapter over the frozen controller, never a second
# wheel/app lifecycle implementation.
grep -Fq 'FLMLandscapeWheelPresentRootController(self, fromRight);' "$adapter"
grep -Fq 'FLMLandscapeModulePrepareSharedScene(self' "$adapter"
grep -Fq 'engine=FLMWheelController' "$adapter"
grep -Fq 'NSClassFromString(@"FLMWheelItemView")' "$wheel"
grep -Fq 'itemClass=FLMWheelItemView' "$wheel"
grep -Fq '[root dismissWheelLaunchingItem:selectedItem];' "$wheel"
grep -Fq '[root pinWheel];' "$wheel"
grep -Fq 'FLMLandscapeResolveCornerTouch' "$wheel"
grep -Fq 'shared-touch-delegate' "$wheel"
grep -Fq 'entry-touch-accepted' "$wheel"
if grep -Fq 'BOOL accepted = context.valid &&' "$wheel"; then
    echo "transient interface orientation returned as a touch gate" >&2
    exit 1
fi
grep -Fq 'FLMLandscapeRearmRootInput(root);' "$module"
grep -Fq 'landscape-input-rearm' "$module"
grep -Fq '%hook FLMHotspotWindow' "$adapter"
grep -Fq 'input-only fallback' "$adapter"

if grep -Eq '@implementation[[:space:]]+FLMLandscape(WheelController|WheelItemView|Module)' \
    "$wheel" "$module"; then
    echo "independent landscape controller/item implementation detected" >&2
    exit 1
fi
if grep -Eq 'FLMLandscapeModule(OpenIdentifier|Close|HasVisibleCard)|FLMLandscapeSceneEntity|SBDeviceApplicationSceneEntity|createPresenterWithIdentifier:|launchApplicationWithIdentifier:|openApplicationWithBundleID:' \
    "$wheel" "$module" "$adapter" "$header"; then
    echo "retired independent landscape launch/presenter path detected" >&2
    exit 1
fi
if grep -Fq 'com.codex.flymelandscape' "$wheel" "$module" "$adapter"; then
    echo "retired standalone landscape preference domain detected" >&2
    exit 1
fi

# The shared portrait state machine supplies prewarm, Scene resolution,
# Presenter ownership and close/restore. Landscape changes one server settings
# transaction and one client-orientation transaction only.
prepare_body="$(sed -n '/^BOOL FLMLandscapeModulePrepareSharedScene/,/^void FLMLandscapeModuleBackgroundSharedScene/p' "$module")"
test "$(grep -Fc '[scene activate];' <<<"$prepare_body")" -eq 1
test "$(grep -Fc '[scene updateSettings:mutableSettings withTransitionContext:nil];' <<<"$prepare_body")" -eq 1
test "$(grep -Fc '[scene updateClientSettingsWithBlock:' <<<"$prepare_body")" -eq 1
if grep -Fq 'configureParameters:' <<<"$prepare_body"; then
    echo "unsafe duplicate Scene parameter transaction detected" >&2
    exit 1
fi
test "$(grep -Fc '[root prepareFloatingScene:root.floatingScene' "$module")" -eq 1
grep -Fq 'generation != self.orientationGeneration' "$module"
grep -Fq 'action=single-scene-commit' "$module"
grep -Fq 'close-card-no-fullscreen' "$adapter"
grep -Fq 'FLMLandscapeHostLayoutDepth' "$adapter"
grep -Fq 'FLMLandscapeModulePortraitCanvasSize()' "$adapter"
grep -Fq 'return FLMLandscapeModuleCardFrame();' "$adapter"

# Root FLMWheelController remains the sole private system-gesture owner.
registration_files="$(grep -l 'addGestureRecognizer:toDisplayWithIdentity:' "$workspace"/*.xm || true)"
test "$registration_files" = "$workspace/Tweak.xm"

# Horizontal sources remain modules of FlymeMultitasking.dylib in the same deb.
grep -Fq 'LandscapeWheel.xm LandscapeEntryAdapter.xm LandscapeModule.xm' "$makefile"
if grep -Eq '^TWEAK_NAME.*FlymeLandscape([[:space:]]|$)' "$makefile"; then
    echo "standalone FlymeLandscape tweak target detected" >&2
    exit 1
fi

echo "landscape portrait-engine adapter verified"
