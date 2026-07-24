#!/bin/sh
# Compose one target's flashable BaseOS image from prepared StockMod inputs.
# Usage: ./build-image.sh <target>
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"
TARGET="${1:?usage: $0 <target>}"
[ "$#" -eq 1 ] || { echo "usage: $0 <target>" >&2; exit 2; }
eval "$(python3 "$HERE/tools/device_profile.py" shell "$TARGET")"

WORK="$HERE/work/$TARGET"
SOURCE="$WORK/source.json"
BOOT_PREFIX="$WORK/boot-prefix.img"
OUT="$WORK/baseos-$TARGET.img"

[ -f "$SOURCE" ] || { echo "missing $SOURCE (run prepare-stock.sh $TARGET IMAGE)" >&2; exit 1; }
[ -f "$BOOT_PREFIX" ] || { echo "missing $BOOT_PREFIX (run prepare-stock.sh $TARGET IMAGE)" >&2; exit 1; }
[ -f "$WORK/rootfs.tar" ] || { echo "missing $WORK/rootfs.tar (run build-rootfs.sh $TARGET)" >&2; exit 1; }
python3 "$HERE/tools/source_manifest.py" verify "$SOURCE" "$TARGET"
eval "$(python3 "$HERE/tools/source_manifest.py" shell "$SOURCE" "$TARGET")"
[ "$(stat -f %z "$BOOT_PREFIX")" -eq "$SOURCE_BOOT_PREFIX_SIZE" ] || {
  echo "boot-prefix size no longer matches source.json" >&2; exit 1;
}

"$HERE/tools/make-bootlogo.sh" "$TARGET"

# Sector math for the BaseOS 1.0 seven-partition A/B layout (docs/07).
# Slot A keeps the source firmware's rootfs start because the vendor U-Boot
# environment boots /dev/mmcblk0p5; slot B is the identically sized region
# straight after it and stays unallocated — it is the update target, and not
# being a partition is what keeps it invisible to desktop operating systems.
SLOT_START="$SOURCE_P5_START"
SLOT_SECTORS=$((512 * 2048))
UDISK_SECTORS=$((128 * 2048))
SLOT_B_START=$((SLOT_START + SLOT_SECTORS))
UDISK_START=$((SLOT_START + 2 * SLOT_SECTORS))
PRIMARY_START=$((UDISK_START + UDISK_SECTORS))
TOTAL_SECTORS=$((PRIMARY_START + 64 * 2048 + 2048))
PRIMARY_SECTORS=$((TOTAL_SECTORS - 4 - PRIMARY_START + 1))

# Host-native: image compose is mke2fs/mkfs.vfat/GPT/tar only (aarch64 work is
# earlier). Explicit host platform avoids a cached arm64 image on Intel.
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$WORK":/work -v "$HERE/tools":/tools:ro \
  -e TARGET="$TARGET" -e OUT_NAME="$(basename "$OUT")" \
  -e TOTAL_SECTORS="$TOTAL_SECTORS" \
  -e P2_START="$SOURCE_P2_START" \
  -e SLOT_START="$SLOT_START" -e SLOT_SECTORS="$SLOT_SECTORS" \
  -e SLOT_B_START="$SLOT_B_START" \
  -e UDISK_START="$UDISK_START" -e UDISK_SECTORS="$UDISK_SECTORS" \
  -e PRIMARY_START="$PRIMARY_START" -e PRIMARY_SECTORS="$PRIMARY_SECTORS" \
  alpine:3.20 sh -euc '
  apk add -q e2fsprogs e2fsprogs-extra dosfstools mtools python3 sgdisk

  OUT="/work/$OUT_NAME"
  rm -f "$OUT"

  # Preserve the StockMod boot chain and first four partitions, then resize.
  cp /work/boot-prefix.img "$OUT"
  truncate -s $((TOTAL_SECTORS * 512)) "$OUT"
  python3 /tools/mkgpt.py "$OUT" "$TOTAL_SECTORS" "$SLOT_SECTORS" "$UDISK_SECTORS"

  # The boot-resource partition is preserved except for BaseOS bootlogo.bmp.
  export MTOOLS_SKIP_CHECK=1
  mcopy -o -i "$OUT@@$((P2_START * 512))" /work/bootlogo.bmp ::/bootlogo.bmp
  echo "bootlogo replaced for $TARGET"

  # The vendor 4.9 kernel needs classic ext4 features and a journal. The
  # embedded vendor initramfs mounts p5 with data=ordered.
  EXT4_OPTS="^metadata_csum,^metadata_csum_seed,^64bit,^orphan_file"

  R=/tmp/r; rm -rf "$R"; mkdir "$R"
  tar -xf /work/rootfs.tar -C "$R"
  mke2fs -q -F -t ext4 -O "$EXT4_OPTS" -b 4096 -L rootfs -d "$R" \
    -E offset=$((SLOT_START * 512)) "$OUT" $((SLOT_SECTORS / 8))

  # Slot B is left as zeros on purpose: the first system update writes it.

  mke2fs -q -F -t ext4 -O "$EXT4_OPTS" -b 4096 -L userdata \
    -E offset=$((UDISK_START * 512)) "$OUT" $((UDISK_SECTORS / 8))

  mkfs.vfat -F 32 -n BASEOS -S 512 --offset "$PRIMARY_START" \
    "$OUT" $(((PRIMARY_SECTORS - 2048) / 2)) >/dev/null 2>&1

  # Structural and content verification.
  sgdisk -v "$OUT" | tail -4
  dd if="$OUT" of=/tmp/p5.img bs=512 skip="$SLOT_START" count="$SLOT_SECTORS" status=none
  e2fsck -fn /tmp/p5.img >/dev/null
  echo "p5 rootfs (slot A) ext4 OK"
  dd if="$OUT" of=/tmp/p6.img bs=512 skip="$UDISK_START" count="$UDISK_SECTORS" status=none
  e2fsck -fn /tmp/p6.img >/dev/null
  echo "p6 UDISK ext4 OK"

  # Slot B must be untouched zeros: a stray filesystem there would be applied
  # verbatim by the first gptslot flip.
  if [ "$(dd if="$OUT" bs=512 skip="$SLOT_B_START" count="$SLOT_SECTORS" status=none \
      | tr -d "\0" | wc -c)" -ne 0 ]; then
    echo "FATAL: rootfs slot B is not empty"; exit 1
  fi
  echo "slot B reserved and empty OK"

  debugfs -R "stat /init" /tmp/p5.img 2>/dev/null | grep -q "Type: regular" && echo "p5 /init OK"
  debugfs -R "stat /usr/sbin/gptgrow" /tmp/p5.img 2>/dev/null | grep -q Inode && echo "p5 gptgrow OK"
  debugfs -R "stat /usr/sbin/gptslot" /tmp/p5.img 2>/dev/null | grep -q Inode && echo "p5 gptslot OK"
  debugfs -R "stat /usr/sbin/expand-storage" /tmp/p5.img 2>/dev/null | grep -q "Mode:  0755" && echo "p5 expand-storage exec OK"
  debugfs -R "stat /usr/sbin/baseos-update" /tmp/p5.img 2>/dev/null | grep -q "Mode:  0755" && echo "p5 baseos-update exec OK"
  debugfs -R "cat /etc/baseos-release" /tmp/p5.img 2>/dev/null \
    | grep -qx "BASEOS_TARGET=$TARGET" && echo "p5 target identity OK"

  mcopy -i "$OUT@@$((P2_START * 512))" ::/bootlogo.bmp /tmp/embedded-bootlogo.bmp
  cmp /work/bootlogo.bmp /tmp/embedded-bootlogo.bmp
  minfo -i "$OUT@@$((PRIMARY_START * 512))" 2>/dev/null \
    | grep -E "disk size|cluster size" | head -2
  python3 /tools/source_manifest.py verify-image /work/source.json "$TARGET" \
    /work/boot-prefix.img "$OUT" /tmp/embedded-bootlogo.bmp

  rm -f /tmp/p5.img /tmp/p6.img /tmp/embedded-bootlogo.bmp
  ls -lh "$OUT"
  du -h "$OUT"
'

echo
echo "Image: $OUT"
echo "Flash: ./flash-card.sh $TARGET diskN"
