#!/usr/bin/env python3
"""Build a BaseOS `.bosupd` system-update payload from a composed image.

The payload is the active rootfs slot of a finished image, gzipped, plus a
manifest. Applying it writes those exact bytes into the *inactive* slot of an
installed card and flips the GPT, so the updated device ends up byte-identical
to a freshly flashed one — the same filesystem verified by the same hash.

Integrity is a SHA-256 over the decompressed slot image, printed here so it can
be published next to the download. There is no signature: a signing key would
be a single point of failure for every update, and these images carry no
secrets.

Usage: mkupdate.py IMAGE TARGET VERSION BUILD OUTPUT
"""
import gzip
import hashlib
import io
import struct
import sys
import tarfile
import uuid
from pathlib import Path

SECTOR = 512
CHUNK = 4 * 1024 * 1024
ROOTFS_INDEX = 4


def die(msg):
    sys.exit(f"mkupdate: {msg}")


def rootfs_extent(image: Path) -> tuple[int, int]:
    """Return (start_sector, sector_count) of the `rootfs` partition."""
    with image.open("rb") as handle:
        handle.seek(SECTOR)
        header = handle.read(SECTOR)
        if header[:8] != b"EFI PART":
            die("no primary GPT in the image")
        entries_lba = struct.unpack_from("<Q", header, 72)[0]
        count, size = struct.unpack_from("<II", header, 80)
        handle.seek(entries_lba * SECTOR)
        entry = handle.read(count * size)[ROOTFS_INDEX * size : (ROOTFS_INDEX + 1) * size]
    name = entry[56:128].decode("utf-16-le").rstrip("\0")
    if name != "rootfs":
        die(f"partition 5 is {name!r}, expected 'rootfs'")
    start, end = struct.unpack_from("<QQ", entry, 32)
    return start, end - start + 1


def main() -> int:
    if len(sys.argv) != 6:
        die("usage: mkupdate.py IMAGE TARGET VERSION BUILD OUTPUT")
    image, target, version, build, output = (
        Path(sys.argv[1]),
        sys.argv[2],
        sys.argv[3],
        sys.argv[4],
        Path(sys.argv[5]),
    )

    start, sectors = rootfs_extent(image)
    size = sectors * SECTOR
    print(f"rootfs slot at LBA {start}, {sectors} sectors ({size} bytes)")

    # Stream the slot once: hash it, compress it, and confirm the identity
    # baked into the filesystem matches what we are about to claim about it.
    # Both stamps matter: a manifest that claims a version the filesystem does
    # not carry would make the target apply it, boot, still disagree about its
    # own version, and apply it again.
    digest = hashlib.sha256()
    compressed = io.BytesIO()
    stamps = {
        f"BASEOS_VERSION={version}".encode(): False,
        f"BASEOS_BUILD={build}".encode(): False,
    }
    window = max(len(stamp) for stamp in stamps)
    tail = b""
    with image.open("rb") as handle, gzip.GzipFile(
        fileobj=compressed, mode="wb", compresslevel=6, mtime=0
    ) as gz:
        handle.seek(start * SECTOR)
        remaining = size
        while remaining:
            chunk = handle.read(min(CHUNK, remaining))
            if not chunk:
                die("image is shorter than the rootfs partition it declares")
            remaining -= len(chunk)
            digest.update(chunk)
            gz.write(chunk)
            haystack = tail + chunk
            for stamp, seen in stamps.items():
                if not seen and stamp in haystack:
                    stamps[stamp] = True
            tail = chunk[-window:]

    for stamp, seen in stamps.items():
        if not seen:
            die(f"the image does not contain {stamp.decode()} — rebuild the rootfs first")

    manifest = "".join(
        f"{key}={value}\n"
        for key, value in (
            ("format", "baseos-update/1"),
            ("target", target),
            ("version", version),
            ("build", build),
            ("slot-sectors", sectors),
            ("image-size", size),
            ("image-sha256", digest.hexdigest()),
        )
    ).encode()

    payload = compressed.getvalue()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(output, "w", format=tarfile.USTAR_FORMAT) as archive:
        for name, blob in (("manifest", manifest), ("rootfs.img.gz", payload)):
            info = tarfile.TarInfo(name)
            info.size = len(blob)
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            archive.addfile(info, io.BytesIO(blob))

    print(f"payload:  {output} ({output.stat().st_size} bytes)")
    print(f"target:   {target}")
    print(f"version:  {version} ({build})")
    print(f"sha256:   {digest.hexdigest()}    (publish this next to the download)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
