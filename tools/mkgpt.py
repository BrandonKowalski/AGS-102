#!/usr/bin/env python3
"""GPT surgery for the H700 BaseOS image.

Reads the stock primary GPT already present in the image (from
boot-prefix.img) and rewrites it into the BaseOS 1.0 seven-partition layout:

    1 special  2 boot-resource  3 env  4 boot   (vendor, verbatim)
    5 rootfs      slot A, at the stock p5 start
      (unallocated) slot B, the same size — the A/B update target
    6 UDISK       /data, carrying the stock UDISK entry identity
    7 primary     FAT32 "BASEOS", the only desktop-visible volume
    8 (empty)

The stock `appfs` entry is dropped and the UDISK/primary entries are *shifted*
down a slot, so each partition keeps its stock name, type GUID and unique GUID.
The inactive rootfs slot is deliberately not a partition: it costs no visible
partition and no desktop OS can see it.

Every entry except `primary` gets GPT attribute bits 62 (hidden) and 63 (no
drive letter) so Windows assigns exactly one drive letter for the whole card.
Stock ships all eight partitions as Microsoft Basic Data with attributes 0,
which is why a stock-derived card triggers a format prompt per partition.

Layout conventions mirror the stock table exactly: header at LBA 1, 8 entries
of 128 bytes at LBA 2-3, first usable LBA 4; backup entries at total-3..-2,
backup header at total-1, last usable total-4.

Usage: mkgpt.py IMAGE TOTAL_SECTORS SLOT_SECTORS UDISK_SECTORS
"""
import struct
import sys
import uuid
import zlib

SECTOR = 512
NUM_ENTRIES = 8
ENTRY_SIZE = 128
PRIMARY_TYPE_GUID = uuid.UUID("ebd0a0a2-b9e5-4433-87c0-68b6b72699c7")
PRIMARY_UNIQUE_GUID = uuid.UUID("07c2a8fa-761b-41cc-bc12-ca43eafb5ee5")

# Bit 62 "hidden" + bit 63 "no drive letter".
HIDDEN_ATTRIBUTES = 0xC000000000000000

SOURCE_NAMES = ["special", "boot-resource", "env", "boot", "rootfs", "appfs", "UDISK"]
OUTPUT_NAMES = ["special", "boot-resource", "env", "boot", "rootfs", "UDISK", "primary"]


def die(msg):
    sys.exit(f"mkgpt: {msg}")


def name_of(entry):
    return entry[56:128].decode("utf-16-le").rstrip("\0")


def main():
    img_path, total, slot_sectors, udisk_sectors = (
        sys.argv[1],
        int(sys.argv[2]),
        int(sys.argv[3]),
        int(sys.argv[4]),
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
        source = [bytearray(f.read(ENTRY_SIZE)) for _ in range(NUM_ENTRIES)]

        # StockMod BASE archives deliberately omit p8 and the backup GPT. The
        # known-good H700 full-card layout uses this stable identity for the
        # user-visible `primary` FAT partition; restore it only when slot 8 is
        # completely empty. Full images retain their source entry unchanged.
        if source[7] == bytearray(ENTRY_SIZE):
            source[7][:16] = PRIMARY_TYPE_GUID.bytes_le
            source[7][16:32] = PRIMARY_UNIQUE_GUID.bytes_le
            source[7][56 : 56 + len("primary".encode("utf-16-le"))] = "primary".encode(
                "utf-16-le"
            )

        source_names = [name_of(e) for e in source]
        if source_names[:7] != SOURCE_NAMES:
            die(f"unexpected source partition names: {source_names}")

        # Drop `appfs`; shift UDISK and primary down one slot so every
        # partition keeps its stock name/type GUID/unique GUID.
        entries = source[:5] + [source[6], source[7], bytearray(ENTRY_SIZE)]
        names = [name_of(e) for e in entries]
        if names[:7] != OUTPUT_NAMES:
            die(f"unexpected output partition names: {names}")

        starts = [struct.unpack_from("<Q", e, 32)[0] for e in entries]
        ends = [0] * NUM_ENTRIES
        new_starts = list(starts)

        # p1-p4 keep their stock start and end exactly.
        ends[0:4] = [struct.unpack_from("<Q", entries[i], 40)[0] for i in range(4)]

        slot_base = starts[4]
        if slot_base != ends[3] + 1:
            die("rootfs does not start immediately after the boot partition")

        # Slot A keeps the stock rootfs start; slot B is the identically sized
        # region straight after it and is intentionally left unallocated.
        ends[4] = slot_base + slot_sectors - 1
        new_starts[5] = slot_base + 2 * slot_sectors
        ends[5] = new_starts[5] + udisk_sectors - 1
        new_starts[6] = ends[5] + 1
        last_usable = total - 4
        ends[6] = last_usable
        if new_starts[6] >= ends[6]:
            die("image too small for the requested partition sizes")

        for i in range(NUM_ENTRIES - 1):
            struct.pack_into("<QQ", entries[i], 32, new_starts[i], ends[i])
            # `primary` stays a plain Basic Data volume so desktops mount it;
            # everything else is hidden and gets no drive letter.
            attributes = 0 if names[i] == "primary" else HIDDEN_ATTRIBUTES
            struct.pack_into("<Q", entries[i], 48, attributes)

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

    for i in range(NUM_ENTRIES - 1):
        print(
            f"p{i+1} {names[i]:<14} start={new_starts[i]:>9} "
            f"end={ends[i]:>9} sectors={ends[i]-new_starts[i]+1:>9}"
        )
    print(
        f"-- {'(slot B)':<14} start={slot_base + slot_sectors:>9} "
        f"end={slot_base + 2 * slot_sectors - 1:>9} sectors={slot_sectors:>9} "
        "unallocated"
    )


if __name__ == "__main__":
    main()
