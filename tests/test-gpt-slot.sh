#!/bin/sh
# Offline regression test for the A/B rootfs slot machinery: mkgpt.py's
# seven-partition layout and gptslot's geometry derivation and flip.
#
# Everything runs against synthetic images, so this needs no device, no
# StockMod input and no privileges.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"

# Host-native: gptslot is plain C with no device dependency, so the host-arch
# build exercises exactly the same logic as the aarch64 one.
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$HERE/tools":/src:ro alpine:3.20 sh -euc '
  apk add -q build-base python3
  gcc -static -O2 -I/src -o /usr/local/bin/gptslot /src/gptslot.c

  cat > /tmp/fixture.py <<"PY"
"""Write a stock-shaped H700 8-entry GPT fixture (the pre-1.0 layout)."""
import binascii, struct, sys, uuid

SECTOR, COUNT, ESZ = 512, 8, 128
NAMES = ["special", "boot-resource", "env", "boot", "rootfs", "appfs", "UDISK", "primary"]
BASIC_DATA = uuid.UUID("ebd0a0a2-b9e5-4433-87c0-68b6b72699c7")

path, total = sys.argv[1], int(sys.argv[2])
starts = [2048, 4096, 69632, 71680, 79872]
ends = [4095, 69631, 71679, 79871]
ends.append(starts[4] + 32 * 2048 - 1)          # rootfs
starts.append(ends[4] + 1); ends.append(starts[5] + 8192 - 1)   # appfs
starts.append(ends[5] + 1); ends.append(starts[6] + 8192 - 1)   # UDISK
starts.append(ends[6] + 1); ends.append(total - 4)              # primary

table = bytearray(COUNT * ESZ)
for i, (name, start, end) in enumerate(zip(NAMES, starts, ends)):
    e = bytearray(ESZ)
    e[:16] = BASIC_DATA.bytes_le
    e[16:32] = uuid.UUID(int=0x1000 + i).bytes_le
    struct.pack_into("<QQQ", e, 32, start, end, 0)
    encoded = name.encode("utf-16-le")
    e[56 : 56 + len(encoded)] = encoded
    table[i * ESZ : (i + 1) * ESZ] = e
table_crc = binascii.crc32(bytes(table)) & 0xFFFFFFFF


def header(current, alternate, table_lba):
    h = bytearray(SECTOR)
    h[:8] = b"EFI PART"
    struct.pack_into("<IIII", h, 8, 0x00010000, 92, 0, 0)
    struct.pack_into("<QQQQ", h, 24, current, alternate, 4, total - 4)
    h[56:72] = uuid.UUID(int=0x777).bytes_le
    struct.pack_into("<QIII", h, 72, table_lba, COUNT, ESZ, table_crc)
    struct.pack_into("<I", h, 16, binascii.crc32(h[:92]) & 0xFFFFFFFF)
    return bytes(h)


with open(path, "wb") as f:
    f.truncate(total * SECTOR)
    f.seek(SECTOR); f.write(header(1, total - 1, 2))
    f.seek(2 * SECTOR); f.write(bytes(table))
    f.seek((total - 3) * SECTOR); f.write(bytes(table))
    f.seek((total - 1) * SECTOR); f.write(header(total - 1, 1, total - 3))
PY

  cat > /tmp/inspect.py <<"PY"
"""Print `pN name start end attrs` for a GPT, validating both copies CRCs."""
import binascii, struct, sys

SECTOR, ESZ = 512, 128
path = sys.argv[1]
with open(path, "rb") as f:
    f.seek(SECTOR); head = f.read(SECTOR)
    assert head[:8] == b"EFI PART", "no primary GPT"
    stored = struct.unpack_from("<I", head, 16)[0]
    check = bytearray(head[:92]); struct.pack_into("<I", check, 16, 0)
    assert binascii.crc32(check) & 0xFFFFFFFF == stored, "primary header CRC"
    backup_lba = struct.unpack_from("<Q", head, 32)[0]
    table_lba, count, size, table_crc = struct.unpack_from("<QIII", head, 72)
    f.seek(table_lba * SECTOR); table = f.read(count * size)
    assert binascii.crc32(table) & 0xFFFFFFFF == table_crc, "primary table CRC"

    f.seek(backup_lba * SECTOR); tail = f.read(SECTOR)
    assert tail[:8] == b"EFI PART", "no backup GPT"
    stored = struct.unpack_from("<I", tail, 16)[0]
    check = bytearray(tail[:92]); struct.pack_into("<I", check, 16, 0)
    assert binascii.crc32(check) & 0xFFFFFFFF == stored, "backup header CRC"
    b_table_lba, b_count, b_size, b_table_crc = struct.unpack_from("<QIII", tail, 72)
    f.seek(b_table_lba * SECTOR); b_table = f.read(b_count * b_size)
    assert b_table == table, "primary and backup tables differ"
    assert binascii.crc32(b_table) & 0xFFFFFFFF == b_table_crc, "backup table CRC"

for i in range(count):
    e = table[i * size : (i + 1) * size]
    if e[:16] == b"\0" * 16:
        continue
    start, end, attrs = struct.unpack_from("<QQQ", e, 32)
    name = e[56:128].decode("utf-16-le").rstrip("\0")
    guid = e[16:32].hex()
    print(f"p{i + 1} {name} {start} {end} {attrs:#x} {guid}")
PY

  SLOT=32768        # 16 MiB slots, in sectors
  UDISK=8192
  SLOT_BASE=79872   # the fixture rootfs start, as p5 keeps it
  PRIMARY_START=$((SLOT_BASE + 2 * SLOT + UDISK))
  TOTAL=$((PRIMARY_START + 32768 + 4))

  echo "== pre-1.0 fixture is refused =="
  python3 /tmp/fixture.py /tmp/legacy.img "$TOTAL"
  if gptslot /tmp/legacy.img geometry >/dev/null 2>&1; then
    echo "FAIL: gptslot accepted a pre-1.0 eight-partition layout" >&2
    exit 1
  fi
  echo "ok: an old card cannot be slot-flipped"

  echo "== mkgpt.py produces the 1.0 layout =="
  python3 /tmp/fixture.py /tmp/card.img "$TOTAL"
  python3 /src/mkgpt.py /tmp/card.img "$TOTAL" "$SLOT" "$UDISK" > /tmp/mkgpt.out
  python3 /tmp/inspect.py /tmp/card.img > /tmp/layout.txt
  cat /tmp/layout.txt

  test "$(wc -l < /tmp/layout.txt)" -eq 7 || { echo "FAIL: expected 7 partitions" >&2; exit 1; }
  grep -q "^p5 rootfs $SLOT_BASE $((SLOT_BASE + SLOT - 1)) 0xc000000000000000 " /tmp/layout.txt \
    || { echo "FAIL: rootfs slot A geometry/attributes" >&2; exit 1; }
  grep -q "^p6 UDISK $((SLOT_BASE + 2 * SLOT)) " /tmp/layout.txt \
    || { echo "FAIL: UDISK must start exactly two slots in" >&2; exit 1; }
  grep -q "^p7 primary $PRIMARY_START $((TOTAL - 4)) 0x0 " /tmp/layout.txt \
    || { echo "FAIL: primary must stay a visible Basic Data volume" >&2; exit 1; }
  # Everything except the user-visible FAT volume is hidden from desktops.
  if grep -v "^p7 " /tmp/layout.txt | grep -qv " 0xc000000000000000 "; then
    echo "FAIL: a non-primary partition is missing the hidden attributes" >&2
    exit 1
  fi
  echo "ok: seven partitions, one visible volume, slot B unallocated"

  echo "== gptslot geometry and flip =="
  gptslot /tmp/card.img geometry > /tmp/geom.txt
  cat /tmp/geom.txt
  . /tmp/geom.txt
  test "$SLOT_ACTIVE" = A || { echo "FAIL: fresh image must be slot A" >&2; exit 1; }
  test "$SLOT_SECTORS" = "$SLOT" || { echo "FAIL: slot size" >&2; exit 1; }
  test "$SLOT_INACTIVE_START" = "$((SLOT_BASE + SLOT))" \
    || { echo "FAIL: inactive slot offset" >&2; exit 1; }

  cp /tmp/card.img /tmp/card-a.img
  gptslot /tmp/card.img flip
  python3 /tmp/inspect.py /tmp/card.img > /tmp/layout-b.txt
  gptslot /tmp/card.img geometry > /tmp/geom-b.txt
  . /tmp/geom-b.txt
  test "$SLOT_ACTIVE" = B || { echo "FAIL: flip did not select slot B" >&2; exit 1; }
  grep -q "^p5 rootfs $((SLOT_BASE + SLOT)) $((SLOT_BASE + 2 * SLOT - 1)) " /tmp/layout-b.txt \
    || { echo "FAIL: flipped rootfs extent" >&2; exit 1; }
  # Name, attributes and unique GUID must survive a flip untouched: only the
  # extent moves, so U-Boot still builds the same partitions= cmdline.
  test "$(awk "/^p5 /{print \$2, \$5, \$6}" /tmp/layout.txt)" \
     = "$(awk "/^p5 /{print \$2, \$5, \$6}" /tmp/layout-b.txt)" \
    || { echo "FAIL: flip changed rootfs identity" >&2; exit 1; }
  # Every other partition is byte-identical.
  grep -v "^p5 " /tmp/layout.txt > /tmp/others-a.txt
  grep -v "^p5 " /tmp/layout-b.txt > /tmp/others-b.txt
  cmp /tmp/others-a.txt /tmp/others-b.txt \
    || { echo "FAIL: flip disturbed another partition" >&2; exit 1; }
  echo "ok: flip moves only the rootfs extent"

  echo "== flip is an involution =="
  gptslot /tmp/card.img flip
  cmp /tmp/card.img /tmp/card-a.img \
    || { echo "FAIL: flipping twice did not restore the original image" >&2; exit 1; }
  echo "ok: two flips restore the card byte-for-byte"

  echo "RESULT: PASS — A/B slot layout, geometry, flip and rollback"
'
