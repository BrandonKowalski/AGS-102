#!/usr/bin/env python3
"""Create a tiny deterministic 8-entry H700-like GPT fixture for tests."""

from __future__ import annotations

import argparse
import binascii
import struct
import subprocess
import uuid
from pathlib import Path

SECTOR = 512
ENTRY_COUNT = 8
ENTRY_SIZE = 128
NAMES = ["special", "boot-resource", "env", "boot", "rootfs", "appfs", "UDISK", "primary"]
LINUX_FS = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")
DISK_GUID = uuid.UUID("8dc79b8d-07aa-5c52-99ad-10a68d7d11e3")


def make_header(total: int, table_crc: int, current: int, alternate: int, table_lba: int) -> bytes:
    header = bytearray(SECTOR)
    header[:8] = b"EFI PART"
    struct.pack_into("<IIII", header, 8, 0x00010000, 92, 0, 0)
    struct.pack_into("<QQQQ", header, 24, current, alternate, 4, total - 4)
    header[56:72] = DISK_GUID.bytes_le
    struct.pack_into("<QIII", header, 72, table_lba, ENTRY_COUNT, ENTRY_SIZE, table_crc)
    struct.pack_into("<I", header, 16, binascii.crc32(header[:92]) & 0xFFFFFFFF)
    return bytes(header)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("root", type=Path)
    parser.add_argument("--first-name", default="special")
    parser.add_argument("--root-size-mib", type=int, default=32)
    parser.add_argument(
        "--stockmod-base",
        action="store_true",
        help="omit p8 and the backup GPT, ending the file exactly after p7",
    )
    arguments = parser.parse_args()
    if arguments.root_size_mib < 16:
        raise ValueError("root fixture must be at least 16 MiB")

    # p1-p4 use compact test sizes. p5 is configurable so the same fixture
    # generator can exercise the full rootfs/image integration path.
    starts = [2048, 4096, 69632, 71680, 79872]
    ends = [4095, 69631, 71679, 79871]
    ends.append(starts[4] + arguments.root_size_mib * 2048 - 1)
    starts.extend([ends[4] + 1, ends[4] + 1 + 8192, ends[4] + 1 + 16384])
    ends.extend([starts[5] + 8192 - 1, starts[6] + 8192 - 1])
    total = starts[7] + 32768 + 4
    ends.append(total - 4)
    names = [arguments.first_name, *NAMES[1:]]

    entries = bytearray(ENTRY_COUNT * ENTRY_SIZE)
    for index, (name, start, end) in enumerate(zip(names, starts, ends)):
        if arguments.stockmod_base and index == 7:
            continue
        offset = index * ENTRY_SIZE
        entries[offset : offset + 16] = LINUX_FS.bytes_le
        unique = uuid.uuid5(DISK_GUID, f"fixture-{index + 1}-{name}")
        entries[offset + 16 : offset + 32] = unique.bytes_le
        struct.pack_into("<QQQ", entries, offset + 32, start, end, 0)
        encoded = name.encode("utf-16-le")
        entries[offset + 56 : offset + 56 + len(encoded)] = encoded
    table_crc = binascii.crc32(entries) & 0xFFFFFFFF

    arguments.image.parent.mkdir(parents=True, exist_ok=True)
    file_sectors = ends[6] + 1 if arguments.stockmod_base else total
    with arguments.image.open("wb") as image:
        image.truncate(file_sectors * SECTOR)
        mbr = bytearray(SECTOR)
        mbr[446 + 4] = 0xEE
        struct.pack_into("<II", mbr, 446 + 8, 1, total - 1)
        mbr[510:512] = b"\x55\xaa"
        image.seek(0)
        image.write(mbr)
        image.seek(SECTOR)
        image.write(make_header(total, table_crc, 1, total - 1, 2))
        image.write(entries)
        if not arguments.stockmod_base:
            image.seek((total - 3) * SECTOR)
            image.write(entries)
            image.seek((total - 1) * SECTOR)
            image.write(make_header(total, table_crc, total - 1, 1, total - 3))

    p5_sectors = ends[4] - starts[4] + 1
    subprocess.run(
        [
            "mke2fs",
            "-q",
            "-F",
            "-t",
            "ext4",
            "-d",
            str(arguments.root),
            "-E",
            f"offset={starts[4] * SECTOR}",
            str(arguments.image),
            str(p5_sectors // 8),
        ],
        check=True,
    )
    # p2 is a real FAT boot-resource fixture so build-image.sh can exercise
    # its target-sized bootlogo replacement with mtools.
    subprocess.run(
        [
            "mkfs.vfat",
            "-F",
            "16",
            "-n",
            "BOOT",
            "--offset",
            str(starts[1]),
            str(arguments.image),
            str((ends[1] - starts[1] + 1) // 2),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
