#!/usr/bin/env python3
"""GPT surgery for the H700 base OS image.

Reads the stock primary GPT already present in the image (from
boot-prefix.img), keeps partition names/types/GUIDs and the start offsets of
p1-p5, resizes p5-p7 to the given sector counts, makes p8 fill the remaining
space, and writes a valid primary + backup GPT for the target image size.

Layout conventions mirror the stock table exactly: header at LBA 1, 8 entries
of 128 bytes at LBA 2-3, first usable LBA 4; backup entries at total-3..-2,
backup header at total-1, last usable total-4.

Usage: mkgpt.py IMAGE TOTAL_SECTORS P5_SECTORS P6_SECTORS P7_SECTORS
"""
import struct
import sys
import zlib

SECTOR = 512
NUM_ENTRIES = 8
ENTRY_SIZE = 128


def die(msg):
    sys.exit(f"mkgpt: {msg}")


def main():
    img_path, total, p5s, p6s, p7s = (
        sys.argv[1],
        int(sys.argv[2]),
        int(sys.argv[3]),
        int(sys.argv[4]),
        int(sys.argv[5]),
    )

    with open(img_path, "r+b") as f:
        f.seek(SECTOR)
        hdr = bytearray(f.read(92))
        if hdr[:8] != b"EFI PART":
            die("no primary GPT found in image")
        entries_lba = struct.unpack_from("<Q", hdr, 72)[0]
        n_entries, esz = struct.unpack_from("<II", hdr, 80)
        if n_entries != NUM_ENTRIES or esz != ENTRY_SIZE:
            die(f"unexpected entry table shape: {n_entries}x{esz}")
        f.seek(entries_lba * SECTOR)
        entries = [bytearray(f.read(ENTRY_SIZE)) for _ in range(NUM_ENTRIES)]

        starts = [struct.unpack_from("<Q", e, 32)[0] for e in entries]
        names = [e[56:128].decode("utf-16-le").rstrip("\0") for e in entries]
        if names[:5] != ["special", "boot-resource", "env", "boot", "rootfs"]:
            die(f"unexpected partition names: {names}")

        last_usable = total - 4
        # p1-p4 keep start+end; p5 keeps start with new size; p6/p7 packed
        # after; p8 fills to last usable.
        ends = [0] * NUM_ENTRIES
        new_starts = list(starts)
        ends[0:4] = [struct.unpack_from("<Q", entries[i], 40)[0] for i in range(4)]
        ends[4] = starts[4] + p5s - 1
        new_starts[5] = ends[4] + 1
        ends[5] = new_starts[5] + p6s - 1
        new_starts[6] = ends[5] + 1
        ends[6] = new_starts[6] + p7s - 1
        new_starts[7] = ends[6] + 1
        ends[7] = last_usable
        if new_starts[7] >= ends[7]:
            die("image too small for the requested partition sizes")

        for i, e in enumerate(entries):
            struct.pack_into("<QQ", e, 32, new_starts[i], ends[i])

        table = b"".join(bytes(e) for e in entries)
        table_crc = zlib.crc32(table) & 0xFFFFFFFF
        backup_entries_lba = total - 3
        backup_hdr_lba = total - 1

        def make_header(current_lba, other_lba, part_lba):
            h = bytearray(hdr)
            struct.pack_into("<I", h, 16, 0)  # header crc placeholder
            struct.pack_into("<QQ", h, 24, current_lba, other_lba)
            struct.pack_into("<QQ", h, 40, 4, last_usable)
            struct.pack_into("<Q", h, 72, part_lba)
            struct.pack_into("<I", h, 88, table_crc)
            crc = zlib.crc32(bytes(h[:92])) & 0xFFFFFFFF
            struct.pack_into("<I", h, 16, crc)
            return bytes(h[:92]) + b"\0" * (SECTOR - 92)

        # primary
        f.seek(SECTOR)
        f.write(make_header(1, backup_hdr_lba, 2))
        f.seek(2 * SECTOR)
        f.write(table + b"\0" * (2 * SECTOR - len(table)))
        # backup
        f.seek(backup_entries_lba * SECTOR)
        f.write(table + b"\0" * (2 * SECTOR - len(table)))
        f.write(make_header(backup_hdr_lba, 1, backup_entries_lba))

        # protective MBR: cover the whole target disk
        f.seek(0)
        mbr = bytearray(f.read(SECTOR))
        struct.pack_into("<I", mbr, 446 + 12, min(total - 1, 0xFFFFFFFF))
        f.seek(0)
        f.write(mbr)

    for i in range(NUM_ENTRIES):
        print(
            f"p{i+1} {names[i]:<14} start={new_starts[i]:>9} "
            f"end={ends[i]:>9} sectors={ends[i]-new_starts[i]+1:>9}"
        )


if __name__ == "__main__":
    main()
