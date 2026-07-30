#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: codesign-macho.sh [CODESIGN_OPTIONS...] MACH_O" >&2
    exit 2
fi

argument_count=$#
target="${!argument_count}"
if [[ ! -f "$target" ]]; then
    echo "Mach-O to sign does not exist: $target" >&2
    exit 1
fi

codesign_arguments=()
argument_index=1
while (( argument_index < argument_count )); do
    codesign_arguments+=("${!argument_index}")
    ((argument_index += 1))
done

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/flyme-codesign.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

# Signing a Mach-O while it sits inside a directory ending in ".bundle" makes
# Apple's codesign infer an app-style resource envelope. Jailbreak bundles are
# loaded as dynamic libraries, so sign the binary in isolation and copy the
# signed bytes back into the Theos output path.
temporary_target="$temporary_directory/$(basename "$target")"
cp -p "$target" "$temporary_target"
/usr/bin/codesign "${codesign_arguments[@]}" "$temporary_target"
cp -p "$temporary_target" "$target"
