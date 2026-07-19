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


def parse_gpt(image: Path) -> dict:
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
            if names != EXPECTED_NAMES:
                raise ValueError(f"unexpected partition names/order: {names}")
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
    if not image.name.upper().startswith(profile["stockmod_prefix"].upper()):
        raise ValueError(
            f"{image.name} does not match {arguments.target} "
            f"({profile['stockmod_prefix']}*.img)"
        )

    layout = parse_gpt(image)
    root_partition = layout["partitions"][4]
    prefix_size = root_partition["start_sector"] * SECTOR_SIZE
    source_size = image.stat().st_size
    source_hash = sha256_file(image)

    output = arguments.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="baseos-prepare-") as temporary_name:
        temporary = Path(temporary_name)
        boot_prefix = temporary / "boot-prefix.img"
        harvest = temporary / "stock-harvest.tar"
        root_image = temporary / "stock-rootfs.ext4"
        copy_range(image, boot_prefix, 0, prefix_size)
        copy_range(
            image,
            root_image,
            root_partition["start_sector"] * SECTOR_SIZE,
            root_partition["sector_count"] * SECTOR_SIZE,
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
            "provenance": "stockmod-image",
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
