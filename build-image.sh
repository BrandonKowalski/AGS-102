#!/bin/sh
# Compose one target's flashable BaseOS image from prepared StockMod inputs.
# Usage: ./build-image.sh <target>
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
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

# Sector math. p5 retains the source firmware start; BaseOS repacks p5-p8.
P5_START="$SOURCE_P5_START"
P5_SECTORS=$((512 * 2048))
P6_SECTORS=$((16 * 2048))
P7_SECTORS=$((128 * 2048))
P6_START=$((P5_START + P5_SECTORS))
P7_START=$((P6_START + P6_SECTORS))
P8_START=$((P7_START + P7_SECTORS))
TOTAL_SECTORS=$((P8_START + 64 * 2048 + 2048))
P8_SECTORS=$((TOTAL_SECTORS - 4 - P8_START + 1))

docker run --rm --platform linux/arm64 \
  -v "$WORK":/work -v "$HERE/tools":/tools:ro \
  -e TARGET="$TARGET" -e OUT_NAME="$(basename "$OUT")" \
  -e TOTAL_SECTORS="$TOTAL_SECTORS" \
  -e P2_START="$SOURCE_P2_START" \
  -e P5_START="$P5_START" -e P5_SECTORS="$P5_SECTORS" \
  -e P6_START="$P6_START" -e P6_SECTORS="$P6_SECTORS" \
  -e P7_START="$P7_START" -e P7_SECTORS="$P7_SECTORS" \
  -e P8_START="$P8_START" -e P8_SECTORS="$P8_SECTORS" \
  alpine:3.20 sh -euc '
  apk add -q e2fsprogs e2fsprogs-extra dosfstools mtools python3 sgdisk

  OUT="/work/$OUT_NAME"
  rm -f "$OUT"

  # Preserve the StockMod boot chain and first four partitions, then resize.
  cp /work/boot-prefix.img "$OUT"
  truncate -s $((TOTAL_SECTORS * 512)) "$OUT"
  python3 /tools/mkgpt.py "$OUT" "$TOTAL_SECTORS" \
    "$P5_SECTORS" "$P6_SECTORS" "$P7_SECTORS"

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
    -E offset=$((P5_START * 512)) "$OUT" $((P5_SECTORS / 8))

  mke2fs -q -F -t ext4 -O "$EXT4_OPTS" -b 4096 -L appfs \
    -E offset=$((P6_START * 512)) "$OUT" $((P6_SECTORS / 8))

  mke2fs -q -F -t ext4 -O "$EXT4_OPTS" -b 4096 -L userdata \
    -E offset=$((P7_START * 512)) "$OUT" $((P7_SECTORS / 8))

  mkfs.vfat -F 32 -n BASEOS -S 512 --offset "$P8_START" \
    "$OUT" $(((P8_SECTORS - 2048) / 2)) >/dev/null 2>&1

  # Structural and content verification.
  sgdisk -v "$OUT" | tail -4
  for part in 5 6 7; do
    eval start=\$P${part}_START
    eval sectors=\$P${part}_SECTORS
    dd if="$OUT" of="/tmp/p${part}.img" bs=512 skip="$start" count="$sectors" status=none
    e2fsck -fn "/tmp/p${part}.img" >/dev/null
    echo "p${part} ext4 OK"
  done
  debugfs -R "stat /init" /tmp/p5.img 2>/dev/null | grep -q "Type: regular" && echo "p5 /init OK"
  debugfs -R "stat /usr/sbin/gptgrow" /tmp/p5.img 2>/dev/null | grep -q Inode && echo "p5 gptgrow OK"
  debugfs -R "stat /usr/sbin/expand-storage" /tmp/p5.img 2>/dev/null | grep -q "Mode:  0755" && echo "p5 expand-storage exec OK"
  debugfs -R "cat /etc/baseos-release" /tmp/p5.img 2>/dev/null \
    | grep -qx "BASEOS_TARGET=$TARGET" && echo "p5 target identity OK"

  mcopy -i "$OUT@@$((P2_START * 512))" ::/bootlogo.bmp /tmp/embedded-bootlogo.bmp
  cmp /work/bootlogo.bmp /tmp/embedded-bootlogo.bmp
  minfo -i "$OUT@@$((P8_START * 512))" 2>/dev/null \
    | grep -E "disk size|cluster size" | head -2
  python3 /tools/source_manifest.py verify-image /work/source.json "$TARGET" \
    /work/boot-prefix.img "$OUT" /tmp/embedded-bootlogo.bmp

  rm -f /tmp/p5.img /tmp/p6.img /tmp/p7.img /tmp/embedded-bootlogo.bmp
  ls -lh "$OUT"
  du -h "$OUT"
'

echo
echo "Image: $OUT"
echo "Flash: ./flash-card.sh $TARGET diskN"
