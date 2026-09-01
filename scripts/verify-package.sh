#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -ne 1 ]]; then
    echo "usage: verify-package.sh PACKAGE.deb" >&2
    exit 2
fi

package="$1"
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

dpkg-deb --info "$package"
dpkg-deb --contents "$package"
dpkg-deb --extract "$package" "$workspace/root"
dpkg-deb --control "$package" "$workspace/control"

archive_directories="$(
    dpkg-deb --contents "$package" |
        awk '$1 ~ /^d/ { print $NF }' |
        sed -e 's#^\./##' -e 's#/$##'
)"
for directory in \
    "var" \
    "var/jb" \
    "var/jb/Library" \
    "var/jb/Library/MobileSubstrate" \
    "var/jb/Library/MobileSubstrate/DynamicLibraries" \
    "var/jb/Library/PreferenceBundles" \
    "var/jb/Library/PreferenceBundles/FlymeMultitaskingPrefs.bundle" \
    "var/jb/Library/PreferenceLoader" \
    "var/jb/Library/PreferenceLoader/Preferences"; do
    if ! grep -Fxq "$directory" <<<"$archive_directories"; then
        echo "package archive is missing directory entry: $directory" >&2
        exit 1
    fi
done

test -d "$workspace/root/var/jb/Library/MobileSubstrate/DynamicLibraries"
test -d "$workspace/root/var/jb/Library/PreferenceBundles/FlymeMultitaskingPrefs.bundle"
test -d "$workspace/root/var/jb/Library/PreferenceLoader/Preferences"

runtime="$workspace/root/var/jb/Library/MobileSubstrate/DynamicLibraries/FlymeMultitasking.dylib"
keyboard="$workspace/root/var/jb/Library/MobileSubstrate/DynamicLibraries/FlymeKeyboard.dylib"
preferences="$workspace/root/var/jb/Library/PreferenceBundles/FlymeMultitaskingPrefs.bundle/FlymeMultitaskingPrefs"
filter="$workspace/root/var/jb/Library/MobileSubstrate/DynamicLibraries/FlymeMultitasking.plist"
keyboard_filter="$workspace/root/var/jb/Library/MobileSubstrate/DynamicLibraries/FlymeKeyboard.plist"
loader="$workspace/root/var/jb/Library/PreferenceLoader/Preferences/com.codex.flymemultitasking.plist"
preferences_root="$workspace/root/var/jb/Library/PreferenceBundles/FlymeMultitaskingPrefs.bundle/Root.plist"

test -f "$runtime"
test -f "$keyboard"
test -f "$preferences"
test -f "$filter"
test -f "$loader"
test -f "$preferences_root"
grep -q "centeredCardWidth" "$preferences_root"
grep -q "centeredCardTopCrop" "$preferences_root"
grep -q "centeredCardBottomCrop" "$preferences_root"
grep -q "centeredDockSwipeThreshold" "$preferences_root"
grep -q "dockedShrinkAmount" "$preferences_root"
grep -q "cornerTriggerSizeV2" "$preferences_root"
if grep -q "centeredCardHeight" "$preferences_root"; then
    echo "preferences still exposes the removed logical card-height setting" >&2
    exit 1
fi
test -f "$keyboard_filter"
grep -q "Bundles" "$keyboard_filter"
grep -q "com.apple.UIKit" "$keyboard_filter"
grep -q "com.tencent.xin" "$keyboard_filter"
if grep -Eq "UIApplication|Executables|Classes" "$keyboard_filter"; then
    echo "keyboard adapter must remain bundle-scoped" >&2
    exit 1
fi
test ! -e "$workspace/root/var/jb/Library/MobileSubstrate/DynamicLibraries/FlymeKeyboardBootstrap.dylib"
test ! -e "$workspace/root/var/jb/Library/MobileSubstrate/DynamicLibraries/FlymeKeyboardBootstrap.plist"
test -f "$workspace/root/var/jb/Library/PreferenceBundles/FlymeMultitaskingPrefs.bundle/icon.png"
test -f "$workspace/root/var/jb/Library/PreferenceBundles/FlymeMultitaskingPrefs.bundle/icon@2x.png"
test -f "$workspace/root/var/jb/Library/PreferenceBundles/FlymeMultitaskingPrefs.bundle/icon@3x.png"

runtime_arches="$(xcrun lipo -archs "$runtime")"
keyboard_arches="$(xcrun lipo -archs "$keyboard")"
preferences_arches="$(xcrun lipo -archs "$preferences")"
[[ "$runtime_arches" == *"arm64"* && "$runtime_arches" == *"arm64e"* ]]
[[ "$keyboard_arches" == *"arm64"* && "$keyboard_arches" == *"arm64e"* ]]
[[ "$preferences_arches" == *"arm64"* && "$preferences_arches" == *"arm64e"* ]]

# Apple's codesign verifier does not recognize ldid's jailbreak-native arm64e
# signature. Validate the embedded CodeDirectory and every code-page hash
# directly, then enforce the same non-CS_ADHOC flags as the working reference.
python3 "$script_directory/verify-macho-signature.py" --require-flags 0 "$runtime"
python3 "$script_directory/verify-macho-signature.py" --require-flags 0 "$keyboard"
runtime_strings="$workspace/runtime.strings"
keyboard_strings="$workspace/keyboard.strings"
# Materialize once instead of piping `strings` into `grep -q`. With pipefail,
# an early grep match closes the pipe and Xcode 15's strings reports a flush
# error even though the binary and expected marker are both valid.
strings "$runtime" >"$runtime_strings"
strings "$keyboard" >"$keyboard_strings"
grep -q "keyboard-app-ctor-v53" "$keyboard_strings"
grep -q "keyboard-app-ready-v53" "$keyboard_strings"
grep -q "keyboard-dismiss-request-reset-v1" "$keyboard_strings"
grep -q "dock-input-block-v1" "$runtime_strings"
grep -q "dock-input-block publish" "$runtime_strings"
grep -q "schema=19" "$runtime_strings"
grep -q "Landscape Experimental 0.9.61" "$runtime_strings"
grep -q "dock-input-block-v1" "$keyboard_strings"
python3 "$script_directory/verify-macho-signature.py" --require-flags 0 "$preferences"

grep -qx "Package: com.codex.flymemultitasking" "$workspace/control/control"
grep -qx "Version: 0.9.61" "$workspace/control/control"
grep -qx "Architecture: iphoneos-arm64" "$workspace/control/control"
test -x "$workspace/control/postinst"
grep -q "generic" "$workspace/control/postinst"
if grep -q "WeChat\|com.tencent.xin" "$workspace/control/postinst"; then
    echo "package maintainer script still contains a hard-coded app target" >&2
    exit 1
fi

if find "$workspace/root" -print | grep -Eiq "TrollOpenJB|charlieleung"; then
    echo "package unexpectedly contains TrollOpen files" >&2
    exit 1
fi

if grep -Riq "dpkg-divert" "$workspace/control"; then
    echo "package unexpectedly contains dpkg-divert maintainer logic" >&2
    exit 1
fi

echo "package verification passed"
