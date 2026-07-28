#!/usr/bin/env python3
"""Prepare BaseOS build inputs from an extracted StockMod disk image."""

from __future__ import annotations

import argparse
import binascii
import hashlib
import json
import os
import shutil
import struct
import subprocess
import tempfile
import uuid
from pathlib import Path

EXPECTED_NAMES = [
    "special",
    "boot-resource",
    "env",
    "boot",
    "rootfs",
    "appfs",
    "UDISK",
    "primary",
]
# The composed BaseOS image drops `appfs` and shifts UDISK/primary down a slot;
# the freed region becomes the unallocated A/B rootfs slot (see mkgpt.py).
BASEOS_NAMES = [
    "special",
    "boot-resource",
    "env",
    "boot",
    "rootfs",
    "UDISK",
    "primary",
    None,
]
# Current Anbernic stock firmware ships a different table: partition 1 is a 2 GiB
# user-visible FAT32 `Roms` volume rather than StockMod's 64 MiB empty `special`,
# everything after it sits ~1.94 GiB higher, and there is no `primary`. StockMod
# is itself a re-partition of stock into the table above, which is what makes the
# same normalisation safe here — see normalise_stock_layout().
STOCK_NAMES = [
    "Roms",
    "boot-resource",
    "env",
    "boot",
    "rootfs",
    "appfs",
    "UDISK",
    None,
]
# `special` in the StockMod table, and what a stock image's `Roms` is rebuilt as.
SPECIAL_SECTORS = 131072  # 64 MiB
SECTOR_SIZE = 512
CHUNK_SIZE = 4 * 1024 * 1024


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(CHUNK_SIZE):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_range(path: Path, offset: int, size: int) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        handle.seek(offset)
        remaining = size
        while remaining:
            chunk = handle.read(min(CHUNK_SIZE, remaining))
            if not chunk:
                raise ValueError(f"short read at byte {offset + size - remaining}")
            digest.update(chunk)
            remaining -= len(chunk)
    return digest.hexdigest()


def parse_gpt(image: Path, expected_names: list | None = None) -> dict:
    """Parse and validate a primary GPT.

    `expected_names` is the full-disk name/order contract. Left unset it accepts
    either recognised firmware table — StockMod's or Anbernic's stock one — and
    reports which in the result's `source_layout`. Composed BaseOS images pass
    BASEOS_NAMES.
    """
    accepted = [expected_names] if expected_names else [EXPECTED_NAMES, STOCK_NAMES]
    image_size = image.stat().st_size
    if image_size % SECTOR_SIZE:
        raise ValueError("disk image size is not a whole number of 512-byte sectors")
    image_sectors = image_size // SECTOR_SIZE
    with image.open("rb") as handle:
        handle.seek(SECTOR_SIZE)
        sector = handle.read(SECTOR_SIZE)
        if len(sector) != SECTOR_SIZE or sector[:8] != b"EFI PART":
            raise ValueError("no primary GPT at LBA 1")
        header_size, header_crc = struct.unpack_from("<II", sector, 12)
        if header_size < 92 or header_size > SECTOR_SIZE:
            raise ValueError(f"invalid GPT header size: {header_size}")
        header = bytearray(sector[:header_size])
        struct.pack_into("<I", header, 16, 0)
        actual_header_crc = binascii.crc32(header) & 0xFFFFFFFF
        if actual_header_crc != header_crc:
            raise ValueError("primary GPT header CRC mismatch")

        current_lba, backup_lba = struct.unpack_from("<QQ", sector, 24)
        first_usable, last_usable = struct.unpack_from("<QQ", sector, 40)
        entries_lba = struct.unpack_from("<Q", sector, 72)[0]
        entry_count, entry_size, entries_crc = struct.unpack_from("<III", sector, 80)
        if current_lba != 1:
            raise ValueError(f"unexpected primary GPT LBA: {current_lba}")
        if entries_lba != 2 or first_usable != 4 or last_usable != backup_lba - 3:
            raise ValueError("unexpected H700 GPT table or usable-LBA geometry")
        if entry_count != 8 or entry_size != 128:
            raise ValueError(f"expected GPT shape 8x128, found {entry_count}x{entry_size}")

        handle.seek(entries_lba * SECTOR_SIZE)
        table = handle.read(entry_count * entry_size)
        if len(table) != entry_count * entry_size:
            raise ValueError("truncated primary GPT entry table")
        if binascii.crc32(table) & 0xFFFFFFFF != entries_crc:
            raise ValueError("primary GPT entry-table CRC mismatch")

        partitions = []
        names: list[str | None] = []
        for index in range(entry_count):
            entry = table[index * entry_size : (index + 1) * entry_size]
            if entry[:16] == b"\0" * 16:
                names.append(None)
                continue
            start, end, attributes = struct.unpack_from("<QQQ", entry, 32)
            name = entry[56:128].decode("utf-16-le", errors="strict").rstrip("\0")
            if start > end:
                raise ValueError(f"GPT partition {index + 1} has an invalid range")
            if start < first_usable or end > last_usable:
                raise ValueError(f"GPT partition {index + 1} lies outside usable LBAs")
            if (end + 1) * SECTOR_SIZE > image_size:
                raise ValueError(f"GPT partition {index + 1} extends beyond the image")
            names.append(name)
            partitions.append(
                {
                    "number": index + 1,
                    "name": name,
                    "type_guid": str(uuid.UUID(bytes_le=entry[:16])),
                    "unique_guid": str(uuid.UUID(bytes_le=entry[16:32])),
                    "start_sector": start,
                    "end_sector": end,
                    "sector_count": end - start + 1,
                    "attributes": attributes,
                }
            )

        if backup_lba == image_sectors - 1:
            packaging = "full-disk"
            if names not in accepted:
                raise ValueError(f"unexpected partition names/order: {names}")
            source_layout = "stock" if names == STOCK_NAMES else "stockmod"
            handle.seek(backup_lba * SECTOR_SIZE)
            backup_sector = handle.read(SECTOR_SIZE)
            if len(backup_sector) != SECTOR_SIZE or backup_sector[:8] != b"EFI PART":
                raise ValueError("no backup GPT at the header-declared LBA")
            backup_size, backup_crc = struct.unpack_from("<II", backup_sector, 12)
            if backup_size < 92 or backup_size > SECTOR_SIZE:
                raise ValueError(f"invalid backup GPT header size: {backup_size}")
            backup_header = bytearray(backup_sector[:backup_size])
            struct.pack_into("<I", backup_header, 16, 0)
            if binascii.crc32(backup_header) & 0xFFFFFFFF != backup_crc:
                raise ValueError("backup GPT header CRC mismatch")
            backup_current, backup_alternate = struct.unpack_from(
                "<QQ", backup_sector, 24
            )
            backup_first_usable, backup_last_usable = struct.unpack_from(
                "<QQ", backup_sector, 40
            )
            backup_entries_lba = struct.unpack_from("<Q", backup_sector, 72)[0]
            backup_count, backup_entry_size, backup_entries_crc = struct.unpack_from(
                "<III", backup_sector, 80
            )
            if backup_current != backup_lba or backup_alternate != 1:
                raise ValueError("backup GPT header points to unexpected LBAs")
            if backup_entries_lba != backup_lba - 2:
                raise ValueError("backup GPT entry table is not in the expected location")
            if (backup_first_usable, backup_last_usable) != (first_usable, last_usable):
                raise ValueError("primary and backup GPT usable-LBA bounds differ")
            if backup_count != entry_count or backup_entry_size != entry_size:
                raise ValueError("primary and backup GPT entry shapes differ")
            if backup_sector[56:72] != sector[56:72]:
                raise ValueError("primary and backup GPT disk GUIDs differ")
            handle.seek(backup_entries_lba * SECTOR_SIZE)
            backup_table = handle.read(backup_count * backup_entry_size)
            if len(backup_table) != len(table):
                raise ValueError("truncated backup GPT entry table")
            if binascii.crc32(backup_table) & 0xFFFFFFFF != backup_entries_crc:
                raise ValueError("backup GPT entry-table CRC mismatch")
            if backup_table != table:
                raise ValueError("primary and backup GPT entry tables differ")
        else:
            # StockMod BASE archives intentionally stop at the end of p7. They
            # retain the valid primary header for the original full disk but
            # omit its empty data partition and unreachable backup GPT.
            packaging = "stockmod-base-trimmed"
            source_layout = "stockmod"
            if names == [*STOCK_NAMES[:7], None] and backup_lba >= image_sectors:
                # A stock image cut short. The boot chain would survive, but the
                # harvest comes out of p5, so there is nothing to prepare from.
                raise ValueError(
                    "this is a truncated stock image; preparing from stock needs the "
                    "whole card, because the rootfs harvest is read from partition 5"
                )
            if backup_lba < image_sectors or names != [*EXPECTED_NAMES[:7], None]:
                raise ValueError("incomplete image is not a recognized StockMod BASE layout")
            if not partitions or partitions[-1]["number"] != 7:
                raise ValueError("StockMod BASE image does not end with partition 7")
            if partitions[-1]["end_sector"] + 1 != image_sectors:
                raise ValueError("StockMod BASE image is not trimmed exactly after partition 7")

    for previous, current in zip(partitions, partitions[1:]):
        if previous["end_sector"] >= current["start_sector"]:
            raise ValueError(f"GPT partitions {previous['number']} and {current['number']} overlap")
    return {
        "packaging": packaging,
        "source_layout": source_layout,
        "backup_gpt_present": packaging == "full-disk",
        "sector_size": SECTOR_SIZE,
        "image_sectors": image_sectors,
        "declared_image_sectors": backup_lba + 1,
        "current_lba": current_lba,
        "backup_lba": backup_lba,
        "first_usable_lba": first_usable,
        "last_usable_lba": last_usable,
        "entry_count": entry_count,
        "entry_size": entry_size,
        "partitions": partitions,
    }


def copy_range(source: Path, destination: Path, offset: int, size: int, sparse: bool = False) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as input_file, destination.open("wb") as output_file:
        input_file.seek(offset)
        remaining = size
        while remaining:
            chunk = input_file.read(min(CHUNK_SIZE, remaining))
            if not chunk:
                raise ValueError(f"source image ended while copying {destination.name}")
            if sparse and not any(chunk):
                output_file.seek(len(chunk), os.SEEK_CUR)
            else:
                output_file.write(chunk)
            remaining -= len(chunk)
        output_file.truncate(size)


def copy_into(source: Path, source_offset: int, size: int, destination: Path, destination_offset: int) -> None:
    """Copy a byte range from one file into an offset in another."""
    with source.open("rb") as input_file, destination.open("r+b") as output_file:
        input_file.seek(source_offset)
        output_file.seek(destination_offset)
        remaining = size
        while remaining:
            chunk = input_file.read(min(CHUNK_SIZE, remaining))
            if not chunk:
                raise ValueError(f"source image ended {remaining} bytes early")
            output_file.write(chunk)
            remaining -= len(chunk)


def normalise_stock_layout(layout: dict) -> dict:
    """Recast a stock table as the StockMod one the rest of the build consumes.

    Stock's partition 1 is a 2 GiB user-visible `Roms` volume where StockMod has
    a 64 MiB empty `special`; shrinking it to 64 MiB and pulling everything after
    it down by the difference reproduces StockMod's table exactly, landing p2-p5
    on the very offsets StockMod uses.

    This is safe because StockMod performs the same re-partition and boots: with
    an RG34XXSP stock and StockMod image side by side, `env` and `boot` are
    byte-identical across the move and U-Boot itself is untouched, because it
    resolves `partitions=` from GPT names and `root=` by partition number rather
    than by address (docs/07 §2). BaseOS drops `Roms` rather than preserving it:
    the composed image supplies its own user-visible `primary` volume.
    """
    partitions = layout["partitions"]
    shift = partitions[0]["sector_count"] - SPECIAL_SECTORS
    if shift <= 0:
        raise ValueError(
            f"stock partition 1 is {partitions[0]['sector_count']} sectors, "
            f"expected more than the {SPECIAL_SECTORS} a `special` needs"
        )

    rebased = []
    for partition_entry in partitions:
        entry = dict(partition_entry)
        if entry["number"] == 1:
            entry["name"] = "special"
            entry["sector_count"] = SPECIAL_SECTORS
            entry["end_sector"] = entry["start_sector"] + SPECIAL_SECTORS - 1
        else:
            entry["start_sector"] -= shift
            entry["end_sector"] -= shift
        rebased.append(entry)

    normalised = dict(layout)
    normalised["partitions"] = rebased
    normalised["normalised_from"] = "stock"
    normalised["shift_sectors"] = shift
    for key in ("image_sectors", "declared_image_sectors", "backup_lba", "last_usable_lba"):
        normalised[key] = layout[key] - shift
    return normalised


def make_empty_special(destination: Path, sectors: int, target: str) -> Path:
    """Build the empty ext4 that a stock card has no equivalent of.

    Every StockMod `special` is an empty ext4 holding nothing but `lost+found`;
    BaseOS preserves it verbatim and never mounts it. A stock card carries a
    FAT32 `Roms` volume there instead, so one is built from scratch.

    Built standalone and copied into place rather than with `mke2fs -E offset=`,
    so `debugfs` can fix the filesystem up without needing offset-aware I/O. The
    UUID and directory hash seed come from the target name and the superblock
    timestamps are zeroed, so re-preparing the same firmware is reproducible --
    an mke2fs run otherwise stamps the wall clock into the result.
    """
    stable = uuid.uuid5(uuid.NAMESPACE_URL, f"baseos:special:{target}")
    # The vendor 4.9 kernel's feature set, matching build-image.sh.
    run(
        [
            "mke2fs", "-q", "-F", "-t", "ext4",
            "-O", "^metadata_csum,^metadata_csum_seed,^64bit,^orphan_file",
            "-b", "4096", "-U", str(stable), "-E", f"hash_seed={stable}",
            str(destination), str(sectors // 8),
        ]
    )
    for field in ("mkfs_time", "mtime", "wtime", "lastcheck"):
        run(
            ["debugfs", "-w", "-R", f"ssv {field} 0", str(destination)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    return destination


def write_normalised_gpt(source: Path, output: Path, normalised: dict) -> None:
    """Rewrite the prefix's primary GPT to describe the normalised table.

    Only the entries move; the header keeps the source disk's GUID and shape.
    build-image.sh hands the result to mkgpt.py, which authors the final table.
    """
    with source.open("rb") as handle:
        handle.seek(SECTOR_SIZE)
        header = bytearray(handle.read(SECTOR_SIZE))
        entries_lba = struct.unpack_from("<Q", header, 72)[0]
        entry_count, entry_size = struct.unpack_from("<II", header, 80)
        handle.seek(entries_lba * SECTOR_SIZE)
        table = bytearray(handle.read(entry_count * entry_size))

    by_number = {p["number"]: p for p in normalised["partitions"]}
    for index in range(entry_count):
        entry = memoryview(table)[index * entry_size : (index + 1) * entry_size]
        partition_entry = by_number.get(index + 1)
        if partition_entry is None:
            continue
        struct.pack_into(
            "<QQ", entry, 32, partition_entry["start_sector"], partition_entry["end_sector"]
        )
        name = partition_entry["name"].encode("utf-16-le")
        entry[56:128] = name.ljust(72, b"\0")

    struct.pack_into("<QQ", header, 40, 4, normalised["last_usable_lba"])
    struct.pack_into("<QQ", header, 24, 1, normalised["backup_lba"])
    struct.pack_into("<I", header, 88, binascii.crc32(bytes(table)) & 0xFFFFFFFF)
    struct.pack_into("<I", header, 16, 0)
    header_size = struct.unpack_from("<I", header, 12)[0]
    struct.pack_into(
        "<I", header, 16, binascii.crc32(bytes(header[:header_size])) & 0xFFFFFFFF
    )

    with output.open("r+b") as handle:
        handle.seek(SECTOR_SIZE)
        handle.write(bytes(header))
        handle.seek(entries_lba * SECTOR_SIZE)
        handle.write(bytes(table))


def build_normalised_prefix(
    image: Path, layout: dict, normalised: dict, output: Path, target: str, temporary: Path
) -> None:
    """Assemble a StockMod-shaped boot prefix from a stock image."""
    special = normalised["partitions"][0]
    prefix_size = normalised["partitions"][4]["start_sector"] * SECTOR_SIZE

    # boot0 and U-Boot, verbatim. StockMod alters only dram_para[28] here (a
    # one-nibble DRAM trim plus its checksum), which is a StockMod tuning choice
    # rather than something the re-partition needs -- so a stock card keeps its
    # own, and BaseOS never invents DRAM timings.
    copy_range(image, output, 0, special["start_sector"] * SECTOR_SIZE)
    with output.open("r+b") as handle:
        handle.truncate(prefix_size)

    staged = make_empty_special(
        temporary / "special.ext4", special["sector_count"], target
    )
    copy_into(staged, 0, special["sector_count"] * SECTOR_SIZE, output,
              special["start_sector"] * SECTOR_SIZE)
    staged.unlink()

    # boot-resource, env and boot move down unchanged. env and boot are proven
    # byte-identical across StockMod's own version of this move.
    for source_entry, target_entry in zip(layout["partitions"][1:4], normalised["partitions"][1:4]):
        copy_into(
            image,
            source_entry["start_sector"] * SECTOR_SIZE,
            source_entry["sector_count"] * SECTOR_SIZE,
            output,
            target_entry["start_sector"] * SECTOR_SIZE,
        )
    write_normalised_gpt(image, output, normalised)


def image_matches_profile(filename: str, profile: dict) -> bool:
    """Is this firmware filename this target's?

    Vendor and StockMod releases alike are named `<MODEL>-...`, which the
    stockmod_prefix pins. `filename_alias` is an escape hatch for images that
    arrive hand-named -- someone's own dump of a card, say -- and is expected to
    fall out of use once an official release exists for the target. Whether an
    image is stock or StockMod is decided by its partition table, never by name.
    """
    upper = filename.upper()
    if upper.startswith(profile["stockmod_prefix"].upper()):
        return True
    alias = profile.get("filename_alias")
    return bool(alias) and alias.upper() in upper


def load_profile(path: Path, target: str) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema") != 1:
        raise ValueError("unsupported device profile schema")
    for profile in data.get("targets", []):
        if profile.get("id") == target:
            return profile
    raise ValueError(f"unknown target: {target}")


def load_harvest_entries(path: Path) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    category = "required"
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line:
            continue
        if line.startswith("##"):
            heading = line[2:].strip().lower()
            if heading == "wifi":
                category = "wifi"
            elif heading.startswith("bluetooth audio stack"):
                category = "bluetooth"
            elif heading.startswith("kernel modules"):
                category = "modules"
            else:
                category = "required"
            continue
        if line.startswith("#"):
            continue
        if not line.startswith("/") or any(character.isspace() for character in line):
            raise ValueError(f"invalid harvest path at {path}:{number}: {raw!r}")
        if line == "/" or ".." in Path(line).parts:
            raise ValueError(f"unsafe harvest path at {path}:{number}: {raw!r}")
        if not any(existing == line for existing, _ in entries):
            entries.append((line, category))
    if not entries:
        raise ValueError("harvest manifest is empty")
    return entries


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(command, check=True, **kwargs)


def omission_allowed(path: str, category: str, profile: dict) -> bool:
    if category == "wifi" and path != "/usr/sbin/fsck.fat":
        return not profile["wifi"]
    if category == "bluetooth":
        return not profile["bluetooth"]
    if category == "modules":
        if path.endswith("/8821cs.ko"):
            return not profile["wifi"]
        if path.endswith("/rtl_btlpm.ko"):
            return not profile["bluetooth"]
    return False


def create_harvest(
    root_partition: Path,
    manifest: Path,
    output: Path,
    temporary: Path,
    profile: dict,
) -> list[str]:
    extracted = temporary / "stock-root"
    extracted.mkdir()
    run(
        ["debugfs", "-R", f"rdump / {extracted}", str(root_partition)],
        stdout=subprocess.DEVNULL,
    )

    entries = load_harvest_entries(manifest)
    busybox = Path("/bin/busybox.static")
    if not busybox.is_file():
        raise RuntimeError("busybox-static is required to resolve stock-root symlinks")
    chroot_busybox = extracted / "busybox"
    shutil.copy2(busybox, chroot_busybox)
    chroot_busybox.chmod(0o755)

    missing_required = []
    optional_omissions = []
    paths = []
    for path, category in entries:
        result = subprocess.run(
            ["chroot", str(extracted), "/busybox", "test", "-e", path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode:
            if omission_allowed(path, category, profile):
                optional_omissions.append(path)
            else:
                missing_required.append(path)
        else:
            paths.append(path)
    if missing_required:
        raise ValueError(
            "required harvest paths are missing: " + ", ".join(missing_required)
        )

    raw_archive = extracted / ".stock-harvest.tar"
    relative_paths = [path.lstrip("/") for path in paths]
    run(
        [
            "chroot",
            str(extracted),
            "/busybox",
            "tar",
            "-chf",
            "/.stock-harvest.tar",
            *relative_paths,
        ]
    )

    # BusyBox tar resolved absolute links inside the chroot. Repack its result
    # with stable ordering, owners, and timestamps for byte-reproducible output.
    normalized = temporary / "normalized-harvest"
    normalized.mkdir()
    run(["tar", "-xf", str(raw_archive), "-C", str(normalized)])
    output.parent.mkdir(parents=True, exist_ok=True)
    run(
        [
            "tar",
            "--sort=name",
            "--mtime=@0",
            "--owner=0",
            "--group=0",
            "--numeric-owner",
            "-cf",
            str(output),
            "-C",
            str(normalized),
            ".",
        ]
    )
    return optional_omissions


def write_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def install_artifact(source: Path, destination: Path) -> None:
    """Atomically install an artifact even when staging and output are separate mounts."""
    temporary = destination.with_name(destination.name + ".tmp")
    try:
        shutil.copyfile(source, temporary)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--profiles", required=True, type=Path)
    arguments = parser.parse_args()

    image = arguments.image.resolve()
    if not image.is_file() or image.suffix.lower() != ".img":
        raise ValueError(f"input must be an extracted .img file: {image}")
    profile = load_profile(arguments.profiles, arguments.target)
    if not image_matches_profile(image.name, profile):
        expected = profile["stockmod_prefix"] + "*.img"
        if profile.get("filename_alias"):
            expected += f", or a filename containing {profile['filename_alias']!r}"
        raise ValueError(f"{image.name} does not match {arguments.target} ({expected})")

    # `source` describes the image on disk and is what every read is addressed
    # through. `layout` describes the prepared prefix: for a StockMod image they
    # are the same table, and for a stock one it is the normalised recast, since
    # everything downstream -- mkgpt.py, build-image.sh, source_manifest.py --
    # speaks the StockMod table and is left untouched by stock support.
    source = parse_gpt(image)
    from_stock = source["source_layout"] == "stock"
    layout = normalise_stock_layout(source) if from_stock else source

    source_root = source["partitions"][4]
    prefix_size = layout["partitions"][4]["start_sector"] * SECTOR_SIZE
    source_size = image.stat().st_size
    source_hash = sha256_file(image)

    output = arguments.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="baseos-prepare-") as temporary_name:
        temporary = Path(temporary_name)
        boot_prefix = temporary / "boot-prefix.img"
        harvest = temporary / "stock-harvest.tar"
        root_image = temporary / "stock-rootfs.ext4"
        if from_stock:
            build_normalised_prefix(
                image, source, layout, boot_prefix, arguments.target, temporary
            )
        else:
            copy_range(image, boot_prefix, 0, prefix_size)
        copy_range(
            image,
            root_image,
            source_root["start_sector"] * SECTOR_SIZE,
            source_root["sector_count"] * SECTOR_SIZE,
            sparse=True,
        )
        with root_image.open("rb") as handle:
            handle.seek(1024 + 56)
            if handle.read(2) != b"\x53\xef":
                raise ValueError("partition 5 is not an ext filesystem")
        optional_omissions = create_harvest(
            root_image,
            arguments.manifest.resolve(),
            harvest,
            temporary,
            profile,
        )

        preserved_regions = []
        for partition in layout["partitions"][:4]:
            size = partition["sector_count"] * SECTOR_SIZE
            offset = partition["start_sector"] * SECTOR_SIZE
            preserved_regions.append(
                {
                    "partition": partition["number"],
                    "name": partition["name"],
                    "start_sector": partition["start_sector"],
                    "sector_count": partition["sector_count"],
                    "sha256": sha256_range(boot_prefix, offset, size),
                }
            )

        metadata = {
            "schema": 1,
            # Kept verbatim so manifests prepared before stock support still
            # load; `source_layout` is what distinguishes the two inputs.
            "provenance": "stockmod-image",
            "source_layout": source["source_layout"],
            "target": profile["id"],
            "model": profile["model"],
            "baseos_device": profile["baseos_device"],
            "model_string": profile["model_string"],
            "capabilities": {
                "wifi": profile["wifi"],
                "bluetooth": profile["bluetooth"],
            },
            "bootlogo": {
                "width": profile["bootlogo_width"],
                "height": profile["bootlogo_height"],
            },
            "source": {
                "filename": image.name,
                "size": source_size,
                "sha256": source_hash,
                # The table as found on the vendor card. For a StockMod image
                # this is `layout`; for a stock one it is what was normalised
                # away, kept so the provenance survives the recast.
                "partitions": source["partitions"],
                "packaging": source["packaging"],
            },
            "layout": layout,
            "boot_prefix": {
                "size": boot_prefix.stat().st_size,
                "sha256": sha256_file(boot_prefix),
            },
            "harvest": {
                "size": harvest.stat().st_size,
                "sha256": sha256_file(harvest),
                "optional_omissions": optional_omissions,
            },
            "preserved_regions": preserved_regions,
        }

        staged_metadata = temporary / "source.json"
        write_json(staged_metadata, metadata)
        install_artifact(boot_prefix, output / "boot-prefix.img")
        install_artifact(harvest, output / "stock-harvest.tar")
        install_artifact(staged_metadata, output / "source.json")
        # A successful preparation changes the source-of-truth contract. Never
        # leave derived artifacts around where they could be mistaken for builds
        # from the newly prepared firmware.
        for name in (
            "rootfs.tar",
            "closure-report.txt",
            "bootlogo.bmp",
            f"baseos-{profile['id']}.img",
        ):
            (output / name).unlink(missing_ok=True)

    print(f"prepared {profile['model']} from {image.name}")
    print(f"  boot prefix: {output / 'boot-prefix.img'}")
    print(f"  harvest:     {output / 'stock-harvest.tar'}")
    print(f"  provenance:  {output / 'source.json'}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"prepare-stock: {error}")
