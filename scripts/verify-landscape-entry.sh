#!/usr/bin/env bash
set -euo pipefail

workspace="${1:-.}"
wheel="$workspace/LandscapeWheel.xm"
adapter="$workspace/LandscapeEntryAdapter.xm"

test -f "$wheel"
test -f "$adapter"

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

# Only the frozen root controller may register with the private system gesture
# manager.  The horizontal module and its adapter only borrow that family.
registration_files="$(grep -l 'addGestureRecognizer:toDisplayWithIdentity:' "$workspace"/*.xm || true)"
test "$registration_files" = "$workspace/Tweak.xm"

echo "landscape entry ownership verified"
