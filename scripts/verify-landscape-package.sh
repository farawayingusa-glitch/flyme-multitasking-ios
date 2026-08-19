#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -ne 1 ]]; then
    echo "usage: verify-landscape-package.sh LANDSCAPE_PACKAGE.deb" >&2
    exit 2
fi

package="$1"
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

dpkg-deb --info "$package"
dpkg-deb --contents "$package"
dpkg-deb --extract "$package" "$workspace/root"
dpkg-deb --control "$package" "$workspace/control"

runtime="$workspace/root/var/jb/Library/MobileSubstrate/DynamicLibraries/FlymeLandscape.dylib"
filter="$workspace/root/var/jb/Library/MobileSubstrate/DynamicLibraries/FlymeLandscape.plist"

test -f "$runtime"
test -f "$filter"
grep -q "com.apple.springboard" "$filter"
test ! -e "$workspace/root/var/jb/Library/MobileSubstrate/DynamicLibraries/FlymeKeyboard.dylib"
test ! -e "$workspace/root/var/jb/Library/MobileSubstrate/DynamicLibraries/FlymeMultitasking.dylib"
grep -q "Package: com.codex.flymelandscape" "$workspace/control/control"
grep -q "Version: 0.1.0" "$workspace/control/control"
grep -q "Architecture: iphoneos-arm64" "$workspace/control/control"
test -x "$workspace/control/postinst"

runtime_arches="$(xcrun lipo -archs "$runtime")"
[[ "$runtime_arches" == *"arm64"* && "$runtime_arches" == *"arm64e"* ]]
python3 "$script_directory/verify-macho-signature.py" --require-flags 0 "$runtime"

strings "$runtime" | grep -q "landscape-scene-contract"
strings "$runtime" | grep -q "landscape-visual-card"
strings "$runtime" | grep -q "landscape-wheel-geometry"
strings "$runtime" | grep -q "keyboardContract=native-scene"
if strings "$runtime" | grep -Eq "FlymeKeyboard|keyboardScreenReferenceSize|updateClientSettingsWithBlock"; then
    echo "landscape package unexpectedly contains the portrait keyboard adapter" >&2
    exit 1
fi

echo "landscape package verification passed"
