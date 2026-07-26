#!/usr/bin/env python3
"""Check that a target's vendor kernel still satisfies the modules BaseOS ships.

BaseOS harvests three vendor kernel modules (mali_kbase, 8821cs, rtl_btlpm) and
loads them against the vendor kernel in partition 4. Nothing in the build would
notice if a refreshed firmware changed that contract: a module whose modversions
no longer match simply fails to insmod on the device, and the GPU or Wi-Fi is
dead. This is the gate that catches it at prepare time instead.

Recovering the kernel's export table is possible even though the vendor ships no
vmlinux and no Module.symvers, because these kernels are CONFIG_RELOCATABLE:
__ksymtab and __kcrctab are zero-filled in the Image and their contents live in
the appended R_AARCH64_RELATIVE (0x403) relocation records as
(r_offset -> r_addend) pairs.

    __ksymtab  entry i at V0 + 16*i  -> addend is the symbol's address
               its name at V0 + 16*i + 8 -> addend points into __ksymtab_strings
    __kcrctab  entry i at C0 + 8*i   -> the addend *is* the CRC, because
               `__kcrctab_sym = (unsigned long)&__crc_sym` and __crc_sym is an
               absolute symbol, so the linker stores the CRC as the addend.

Nothing is trusted on layout alone. The image base is pinned by an anchor symbol
name plus the whole relocation table's address span, and each CRC table is
accepted only when it reproduces CRCs the modules recorded independently in
their own __versions sections. `check` then verifies the modules against the
kernel they shipped beside, which is the control: that must pass before a
cross-target result means anything.

Usage:
  kernel_abi.py check <target> [--modules-from <target>]
  kernel_abi.py exports <target>          # dump the recovered export table
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

R_AARCH64_RELATIVE = 0x403
RELA = 24  # sizeof(Elf64_Rela)
SYMBOL_ENTRY = 16  # sizeof(struct kernel_symbol) on arm64
CRC_ENTRY = 8  # sizeof(unsigned long)
KERNEL_ADDR = 0xFFFF000000000000
MIN_BLOCK = 32  # a real __ksymtab section is far longer than this
SECTOR_SIZE = 512


def die(message: str) -> None:
    raise SystemExit(f"kernel-abi: {message}")


# --- ELF module reading -----------------------------------------------------


def elf_sections(blob: bytes) -> dict[str, bytes]:
    if blob[:4] != b"\x7fELF":
        raise ValueError("not an ELF object")
    table = struct.unpack_from("<Q", blob, 0x28)[0]
    size = struct.unpack_from("<H", blob, 0x3A)[0]
    count = struct.unpack_from("<H", blob, 0x3C)[0]
    strings_index = struct.unpack_from("<H", blob, 0x3E)[0]

    def entry(index: int):
        return struct.unpack_from("<IIQQQQ", blob, table + index * size)

    *_, strings_offset, strings_size = entry(strings_index)
    strings = blob[strings_offset : strings_offset + strings_size]
    sections = {}
    for index in range(count):
        name_offset, kind, _, _, offset, length = entry(index)
        name = strings[name_offset : strings.index(b"\0", name_offset)].decode()
        sections[name] = b"" if kind == 8 else blob[offset : offset + length]
    return sections


def modversions(data: bytes) -> dict[str, int]:
    """{imported symbol: CRC it was built against} from a module's __versions."""
    out: dict[str, int] = {}
    for position in range(0, len(data), 64):
        record = data[position : position + 64]
        if len(record) < 64:
            break
        name = record[8:].split(b"\0")[0].decode()
        if name:
            out[name] = struct.unpack_from("<Q", record, 0)[0]
    return out


def modinfo(data: bytes) -> dict[str, str]:
    out = {}
    for item in data.decode("latin1").split("\0"):
        if "=" in item:
            key, value = item.split("=", 1)
            out.setdefault(key, value)
    return out


def read_modules(harvest: Path) -> dict[str, dict[str, bytes]]:
    """{module name: its ELF sections} for every .ko in the stock harvest.

    Found by suffix rather than by path so a vendor kernel-version bump (which
    moves /usr/lib/modules/<version>/...) still gets checked instead of silently
    matching nothing.
    """
    modules: dict[str, dict[str, bytes]] = {}
    with tarfile.open(harvest) as archive:
        for member in archive:
            if not member.isreg() or not member.name.endswith(".ko"):
                continue
            handle = archive.extractfile(member)
            if handle is None:
                continue
            modules[Path(member.name).name] = elf_sections(handle.read())
    if not modules:
        die(f"no kernel modules found in {harvest}")
    return modules


# --- kernel Image extraction ------------------------------------------------


def extract_kernel(boot_prefix: Path, boot_start_sector: int) -> bytes:
    """The raw arm64 Image out of the ANDROID! boot image in partition 4."""
    with boot_prefix.open("rb") as handle:
        handle.seek(boot_start_sector * SECTOR_SIZE)
        header = handle.read(2048)
        if header[:8] != b"ANDROID!":
            raise ValueError("partition 4 is not an Android boot image")
        kernel_size, _, _, _, _, _, _, page = struct.unpack_from("<8I", header, 8)
        if not 0 < page <= 65536 or page & (page - 1):
            raise ValueError(f"implausible boot image page size {page}")
        handle.seek(boot_start_sector * SECTOR_SIZE + page)
        kernel = handle.read(kernel_size)
    if len(kernel) != kernel_size:
        raise ValueError("boot image is truncated")
    if kernel[56:60] != b"ARMd":
        raise ValueError("kernel is not a raw arm64 Image (missing ARM\\x64 magic)")
    return kernel


# --- export table recovery --------------------------------------------------


def relocations(blob: bytes) -> dict[int, int]:
    """Every R_AARCH64_RELATIVE record as {relocated address: value written}."""
    out: dict[int, int] = {}
    for position in range(0, len(blob) - RELA + 1, 8):
        offset, info, addend = struct.unpack_from("<QQQ", blob, position)
        if info == R_AARCH64_RELATIVE and offset >= KERNEL_ADDR:
            out[offset] = addend
    return out


def read_string(blob: bytes, base: int, address: int) -> str | None:
    offset = address - base
    if not 0 < offset < len(blob) or blob[offset - 1] != 0:
        return None
    end = blob.find(b"\0", offset)
    if not 0 < end - offset <= 128:
        return None
    text = blob[offset:end]
    if not all(32 < byte < 127 for byte in text):
        return None
    return text.decode("ascii")


def solve_base(blob: bytes, relocs: dict[int, int], anchors: list[str]) -> int | None:
    """Image base, pinned by an anchor symbol name and the relocation span.

    The image occupies [base - text_offset, base + image_size): BSS runs past the
    end of the file and the head region sits below `base`, so the file length is
    not the right bound -- the arm64 Image header is. That leaves a handful of
    page-aligned candidates, and the real one is where name pointers resolve to
    actual C strings.
    """
    text_offset, image_size = struct.unpack_from("<QQ", blob, 8)
    lowest, highest = min(relocs), max(relocs)
    pointers = [
        addend
        for address, addend in relocs.items()
        if address % SYMBOL_ENTRY in (0, 8) and addend >= KERNEL_ADDR
    ][:4000]

    for anchor in anchors:
        marker = blob.find(b"\0" + anchor.encode() + b"\0")
        if marker < 0:
            continue
        target = marker + 1
        candidates = {
            addend - target
            for addend in relocs.values()
            if addend >= KERNEL_ADDR
            and (addend - target) % 0x1000 == 0
            and highest - (addend - target) < image_size
            and (addend - target) - text_offset <= lowest
        }
        best, best_score = None, 0
        for base in sorted(candidates):
            score = sum(1 for pointer in pointers if read_string(blob, base, pointer))
            if score > best_score:
                best, best_score = base, score
        if best is not None and best_score >= 100:
            return best
    return None


def symbol_blocks(blob: bytes, relocs: dict[int, int], base: int) -> list[list[str]]:
    """__ksymtab sections as ordered name lists.

    The linker emits each of __ksymtab / __ksymtab_gpl / ..._unused with SORT(),
    so one section is a name-ascending run. Adjacent sections are contiguous in
    memory but each has its own parallel CRC table, so a break in sort order ends
    a block just as an address gap does. Where __ksymtab lands modulo 16 is a
    per-kernel linker artefact, so try both phases and keep whichever resolves.
    """
    named: dict[int, str] = {}
    for phase in (8, 0):
        candidate: dict[int, str] = {}
        for address, addend in relocs.items():
            if address % SYMBOL_ENTRY != phase or addend < KERNEL_ADDR:
                continue
            name = read_string(blob, base, addend)
            if name and (address - 8) in relocs:
                candidate[address - 8] = name
        if len(candidate) > len(named):
            named = candidate

    blocks: list[list[str]] = []
    current: list[str] = []
    previous = None
    for address in sorted(named):
        name = named[address]
        if current and (address != previous + SYMBOL_ENTRY or name < current[-1]):
            if len(current) >= MIN_BLOCK:
                blocks.append(current)
            current = []
        current.append(name)
        previous = address
    if len(current) >= MIN_BLOCK:
        blocks.append(current)
    return blocks


def crc_table(relocs: dict[int, int], block: list[str], known: dict[str, int]) -> dict[str, int]:
    """Locate this block's __kcrctab and read every CRC out of it."""
    index = {name: position for position, name in enumerate(block)}
    usable = sorted((index[name], crc) for name, crc in known.items() if name in index)
    if len(usable) < 4:
        return {}

    by_value: dict[int, list[int]] = {}
    for address, addend in relocs.items():
        if addend < KERNEL_ADDR and address % CRC_ENTRY == 0:
            by_value.setdefault(addend, []).append(address)

    anchor_index, anchor_crc = usable[len(usable) // 2]
    for address in by_value.get(anchor_crc, ()):
        table = address - CRC_ENTRY * anchor_index
        agree = sum(
            1 for position, crc in usable if relocs.get(table + CRC_ENTRY * position) == crc
        )
        if agree >= max(4, int(len(usable) * 0.95)):
            return {
                name: relocs[table + CRC_ENTRY * position]
                for position, name in enumerate(block)
                if table + CRC_ENTRY * position in relocs
            }
    return {}


def exported_crcs(kernel: bytes, known: dict[str, int]) -> dict[str, int]:
    """{name: CRC} for every symbol this kernel exports, per anchorable block."""
    relocs = relocations(kernel)
    if not relocs:
        die("no R_AARCH64_RELATIVE records: this kernel is not CONFIG_RELOCATABLE")
    anchors = sorted(known)[:64]
    base = solve_base(kernel, relocs, anchors)
    if base is None:
        die("could not solve the kernel image base")
    result: dict[str, int] = {}
    for block in symbol_blocks(kernel, relocs, base):
        result.update(crc_table(relocs, block, known))
    if not result:
        die("recovered no export CRC tables")
    return result


# --- the check ---------------------------------------------------------------


def load_inputs(target: str) -> tuple[bytes, dict[str, dict[str, bytes]]]:
    work = ROOT / "work" / target
    source = work / "source.json"
    if not source.is_file():
        die(f"missing {source} (run prepare-stock.sh or fetch-prepared.sh)")
    layout = json.loads(source.read_text(encoding="utf-8"))["layout"]
    boot = next(p for p in layout["partitions"] if p["number"] == 4)
    prefix = work / "boot-prefix.img"
    harvest = work / "stock-harvest.tar"
    for path in (prefix, harvest):
        if not path.is_file():
            die(f"missing {path}")
    return extract_kernel(prefix, boot["start_sector"]), read_modules(harvest)


def check(target: str, modules_from: str | None) -> int:
    kernel, own_modules = load_inputs(target)
    module_target = modules_from or target
    modules = own_modules if module_target == target else load_inputs(module_target)[1]

    expected: dict[str, int] = {}
    vermagics = set()
    for sections in modules.values():
        expected.update(modversions(sections.get("__versions", b"")))
        magic = modinfo(sections.get(".modinfo", b"")).get("vermagic")
        if magic:
            vermagics.add(magic)
    if not expected:
        die(f"{module_target}: modules carry no __versions (built without MODVERSIONS?)")

    table = exported_crcs(kernel, expected)

    missing, mismatched = [], []
    for name, crc in sorted(expected.items()):
        found = table.get(name)
        if found is None:
            missing.append(name)
        elif found != crc:
            mismatched.append((name, found, crc))

    label = target if not modules_from else f"{modules_from} modules on {target} kernel"
    print(f"kernel-abi: {label}")
    print(f"  modules        {len(modules)} ({', '.join(sorted(modules))})")
    print(f"  vermagic       {' | '.join(sorted(vermagics)) or '(none)'}")
    print(f"  kernel exports {len(table)} symbols recovered")
    print(f"  module imports {len(expected)} checked")

    if missing or mismatched:
        for name in missing[:20]:
            print(f"    NOT EXPORTED  {name}")
        for name, found, want in mismatched[:20]:
            print(f"    CRC MISMATCH  {name}: kernel {found:#010x} != module {want:#010x}")
        extra = len(missing) + len(mismatched) - 40
        if extra > 0:
            print(f"    ... and {extra} more")
        print(f"  FAIL: {len(missing)} unexported, {len(mismatched)} mismatched")
        return 1

    print("  OK: every imported symbol is exported with a matching CRC")
    return 0


def exports(target: str) -> int:
    kernel, modules = load_inputs(target)
    known: dict[str, int] = {}
    for sections in modules.values():
        known.update(modversions(sections.get("__versions", b"")))
    for name, crc in sorted(exported_crcs(kernel, known).items()):
        print(f"{crc:#010x} {name}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    subparsers = parser.add_subparsers(dest="command", required=True)
    check_parser = subparsers.add_parser("check")
    check_parser.add_argument("target")
    check_parser.add_argument(
        "--modules-from",
        metavar="TARGET",
        help="check another target's modules against this target's kernel",
    )
    exports_parser = subparsers.add_parser("exports")
    exports_parser.add_argument("target")
    arguments = parser.parse_args()

    if arguments.command == "check":
        return check(arguments.target, arguments.modules_from)
    return exports(arguments.target)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, StopIteration, json.JSONDecodeError) as error:
        raise SystemExit(f"kernel-abi: {error}")
