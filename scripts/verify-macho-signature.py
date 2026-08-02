#!/usr/bin/env python3
"""Inspect embedded Mach-O CodeDirectories without relying on codesign output."""

import argparse
import struct
import sys
from pathlib import Path


FAT_MAGIC = b"\xca\xfe\xba\xbe"
FAT_MAGIC_64 = b"\xca\xfe\xba\xbf"
MH_MAGIC_64_LE = b"\xcf\xfa\xed\xfe"
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSSLOT_REQUIREMENTS = 2
CSSLOT_ALTERNATE_CODEDIRECTORIES = 0x1000


def read_u32(data, offset, endian):
    return struct.unpack_from(endian + "I", data, offset)[0]


def macho_slices(data):
    if data[:4] not in (FAT_MAGIC, FAT_MAGIC_64):
        return [(0, len(data))]
    is_64 = data[:4] == FAT_MAGIC_64
    count = read_u32(data, 4, ">")
    entry_size = 32 if is_64 else 20
    result = []
    for index in range(count):
        base = 8 + index * entry_size
        if is_64:
            offset, size = struct.unpack_from(">QQ", data, base + 8)
        else:
            offset, size = struct.unpack_from(">II", data, base + 8)
        result.append((offset, size))
    return result


def inspect_slice(data, slice_offset, slice_size):
    if data[slice_offset:slice_offset + 4] != MH_MAGIC_64_LE:
        raise ValueError(f"unsupported Mach-O magic at 0x{slice_offset:x}")
    ncmds = read_u32(data, slice_offset + 16, "<")
    command_offset = slice_offset + 32
    signature = None
    for _ in range(ncmds):
        command = read_u32(data, command_offset, "<")
        command_size = read_u32(data, command_offset + 4, "<")
        if command_size < 8:
            raise ValueError("invalid Mach-O load command size")
        if command == LC_CODE_SIGNATURE:
            data_offset = read_u32(data, command_offset + 8, "<")
            data_size = read_u32(data, command_offset + 12, "<")
            signature = (slice_offset + data_offset, data_size)
        command_offset += command_size
    if signature is None:
        raise ValueError("LC_CODE_SIGNATURE is missing")
    signature_offset, signature_size = signature
    if signature_offset + signature_size > slice_offset + slice_size:
        raise ValueError("embedded signature extends beyond its Mach-O slice")
    if read_u32(data, signature_offset, ">") != CSMAGIC_EMBEDDED_SIGNATURE:
        raise ValueError("embedded signature is not a SuperBlob")
    blob_count = read_u32(data, signature_offset + 8, ">")
    code_directories = []
    requirements_length = 0
    alternate_count = 0
    for index in range(blob_count):
        entry = signature_offset + 12 + index * 8
        slot_type = read_u32(data, entry, ">")
        blob_offset = signature_offset + read_u32(data, entry + 4, ">")
        magic = read_u32(data, blob_offset, ">")
        length = read_u32(data, blob_offset + 4, ">")
        if magic == CSMAGIC_CODEDIRECTORY:
            flags = read_u32(data, blob_offset + 12, ">")
            code_directories.append((slot_type, flags, length))
            if slot_type >= CSSLOT_ALTERNATE_CODEDIRECTORIES:
                alternate_count += 1
        elif slot_type == CSSLOT_REQUIREMENTS:
            requirements_length = length
    if not code_directories:
        raise ValueError("CodeDirectory is missing")
    return code_directories, requirements_length, alternate_count


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--require-flags", type=lambda value: int(value, 0))
    parser.add_argument("macho", type=Path)
    arguments = parser.parse_args()
    data = arguments.macho.read_bytes()
    inspected_flags = []
    for index, (offset, size) in enumerate(macho_slices(data)):
        directories, requirements_length, alternate_count = inspect_slice(
            data, offset, size
        )
        flags = [entry[1] for entry in directories]
        print(
            f"slice={index} offset=0x{offset:x} flags="
            f"{','.join(f'0x{value:x}' for value in flags)} "
            f"requirements={requirements_length} alternates={alternate_count}"
        )
        inspected_flags.extend(flags)
    if arguments.require_flags is not None:
        wrong = [
            value for value in inspected_flags
            if value != arguments.require_flags
        ]
        if wrong:
            expected = arguments.require_flags
            raise SystemExit(
                f"unexpected CodeDirectory flags: expected 0x{expected:x}, "
                f"got {','.join(f'0x{value:x}' for value in wrong)}"
            )


if __name__ == "__main__":
    try:
        main()
    except (IndexError, OSError, struct.error, ValueError) as error:
        print(f"signature verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
