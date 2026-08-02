#!/usr/bin/env bash
set -euo pipefail

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

test -f "$runtime"
test -f "$keyboard"
test -f "$preferences"
test -f "$filter"
test -f "$loader"
test -f "$keyboard_filter"
grep -q "com.tencent.xin" "$keyboard_filter"
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

codesign --verify --verbose=4 --all-architectures --strict "$runtime"
codesign --verify --verbose=4 --all-architectures --strict "$keyboard"
# PreferenceLoader loads this Mach-O from a jailbreak resource directory, not
# from an Apple app bundle. Verify every code page and architecture while
# deliberately excluding the app-only resource envelope.
codesign --verify --verbose=4 --all-architectures --strict --ignore-resources "$preferences"

grep -qx "Package: com.codex.flymemultitasking" "$workspace/control/control"
grep -qx "Version: 0.8.37" "$workspace/control/control"
grep -qx "Architecture: iphoneos-arm64" "$workspace/control/control"

if find "$workspace/root" -print | grep -Eiq "TrollOpenJB|charlieleung"; then
    echo "package unexpectedly contains TrollOpen files" >&2
    exit 1
fi

if grep -Riq "dpkg-divert" "$workspace/control"; then
    echo "package unexpectedly contains dpkg-divert maintainer logic" >&2
    exit 1
fi

echo "package verification passed"
