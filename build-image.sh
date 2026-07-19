#!/bin/sh
# Compose the flashable SD image (tiny — ~0.9 GiB; p8 is grown to fill the
# card on first boot). BaseOS ships NO frontend payload — the user copies a
# frontend onto the card after first-boot expansion.
#   [0 .. p5) boot-prefix.img verbatim (GPT + boot0 + U-Boot + p1-p4)
#   p5 rootfs  ext4 512 MiB  <- work/rootfs.tar (build-rootfs.sh)
#   p6 appfs   ext4  16 MiB  empty stub (kept only for partition numbering)
#   p7 UDISK   ext4 128 MiB  /data persistent state
#   p8 primary FAT32 64 MiB  empty; expand-storage grows it to fill the card
# Both GPTs are regenerated for the target size; partition names, type GUIDs,
# unique GUIDs and the p1-p5 start offsets stay identical to stock.
#
# Usage:
#   BOOT_PREFIX=/path/to/boot-prefix.img ./build-image.sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/work"
BOOT_PREFIX="${BOOT_PREFIX:-$HOME/Code/Me/tonky-os/dl/bsp/anbernic-rg40xxv/RG40XXV-V1.1.1.0-EN16GB-260521/boot-prefix.img}"
OUT="$WORK/baseos-h700.img"

[ -f "$WORK/rootfs.tar" ] || { echo "missing $WORK/rootfs.tar (run build-rootfs.sh)"; exit 1; }
[ -f "$BOOT_PREFIX" ] || { echo "missing boot-prefix image: $BOOT_PREFIX"; exit 1; }

# Sector math (kept in sync with tools/mkgpt.py conventions).
P5_START=434176
P5_SECTORS=$((512 * 2048))              # 512 MiB rootfs
P6_SECTORS=$((16 * 2048))               # 16 MiB appfs stub (unused)
P7_SECTORS=$((128 * 2048))              # 128 MiB /data
P6_START=$((P5_START + P5_SECTORS))
P7_START=$((P6_START + P6_SECTORS))
P8_START=$((P7_START + P7_SECTORS))
# p8 ships small (grown on first boot). +1 MiB backup-GPT slack at disk end.
TOTAL_SECTORS=$((P8_START + 64 * 2048 + 2048))
P8_SECTORS=$((TOTAL_SECTORS - 4 - P8_START + 1))

docker run --rm --platform linux/arm64 \
  -v "$WORK":/work -v "$HERE/tools":/tools:ro -v "$HERE/assets":/assets:ro \
  -v "$(dirname "$BOOT_PREFIX")":/bootprefix:ro \
  -e OUT_NAME="$(basename "$OUT")" \
  -e BOOT_PREFIX_NAME="$(basename "$BOOT_PREFIX")" \
  -e TOTAL_SECTORS="$TOTAL_SECTORS" \
  -e P5_START="$P5_START" -e P5_SECTORS="$P5_SECTORS" \
  -e P6_START="$P6_START" -e P6_SECTORS="$P6_SECTORS" \
  -e P7_START="$P7_START" -e P7_SECTORS="$P7_SECTORS" \
  -e P8_START="$P8_START" -e P8_SECTORS="$P8_SECTORS" \
  alpine:3.20 sh -euc '
  apk add -q e2fsprogs dosfstools mtools python3

  OUT="/work/$OUT_NAME"
  rm -f "$OUT"

  ## boot chain + stock GPT, then grow sparsely to target size
  cp "/bootprefix/$BOOT_PREFIX_NAME" "$OUT"
  truncate -s $((TOTAL_SECTORS * 512)) "$OUT"

  ## rewrite both GPTs for this size
  python3 /tools/mkgpt.py "$OUT" "$TOTAL_SECTORS" "$P5_SECTORS" "$P6_SECTORS" "$P7_SECTORS"

  ## Replace the stock bootlogo on the boot-resource partition (p2 @ LBA 204800,
  ## vfat) with our BASE OS splash so the hardware bootlogo -> fbsplash hand-off
  ## is seamless. Same 640x480 24bpp format the vendor uses.
  if [ -f /assets/bootlogo.bmp ]; then
    export MTOOLS_SKIP_CHECK=1
    mcopy -o -i "$OUT@@$((204800 * 512))" /assets/bootlogo.bmp ::/bootlogo.bmp \
      && echo "bootlogo replaced with BASE OS splash"
  fi

  ## ext4 feature policy: the stock 4.9 BSP kernel must mount these. Modern
  ## mke2fs defaults (metadata_csum needs kernel crc32c, metadata_csum_seed,
  ## 64bit, orphan_file on 1.47+) are exactly the kind of thing a vendor
  ## kernel silently lacks — a p5 it cannot mount is an eternal boot splash.
  ## The journal is REQUIRED: the kernel boot image embeds a vendor initramfs
  ## whose init mounts root with "data=ordered", which the kernel rejects on
  ## a journal-less ext4 (this exact combination froze the first two flashes).
  EXT4_OPTS="^metadata_csum,^metadata_csum_seed,^64bit,^orphan_file"

  ## p5: minimal rootfs (read-only at runtime; no journal needed)
  R=/tmp/r; rm -rf "$R"; mkdir "$R"
  tar -xf /work/rootfs.tar -C "$R"
  mke2fs -q -F -t ext4 -O "$EXT4_OPTS" -b 4096 -L rootfs -d "$R" \
    -E offset=$((P5_START * 512)) "$OUT" $((P5_SECTORS / 8))
  # ^ size unit here is 4 KiB blocks: sectors/8

  ## p6: empty appfs stub (kept only for partition numbering)
  mke2fs -q -F -t ext4 -O "$EXT4_OPTS" -b 4096 -L appfs \
    -E offset=$((P6_START * 512)) "$OUT" $((P6_SECTORS / 8))

  ## p7: /data persistent state
  mke2fs -q -F -t ext4 -O "$EXT4_OPTS" -b 4096 -L userdata \
    -E offset=$((P7_START * 512)) "$OUT" $((P7_SECTORS / 8))

  ## p8: empty FAT32, small. Grown to fill the card on first boot by
  ## expand-storage. 1 MiB headroom so mkfs alignment can never extend the
  ## filesystem past the partition into the backup GPT.
  mkfs.vfat -F 32 -n BASEOS -S 512 \
    --offset "$P8_START" "$OUT" $(((P8_SECTORS - 2048) / 2)) >/dev/null 2>&1

  ## verification: GPT integrity, rootfs integrity, FAT readability
  apk add -q sgdisk e2fsprogs-extra
  sgdisk -v "$OUT" | tail -4
  dd if="$OUT" of=/tmp/p5.img bs=512 skip="$P5_START" count="$P5_SECTORS" status=none
  e2fsck -fn /tmp/p5.img >/dev/null && echo "p5 ext4 OK"
  debugfs -R "stat /init" /tmp/p5.img 2>/dev/null | grep -q "Type: symlink" && echo "p5 /init OK"
  debugfs -R "stat /usr/sbin/gptgrow" /tmp/p5.img 2>/dev/null | grep -q Inode && echo "p5 gptgrow OK"
  debugfs -R "stat /usr/sbin/expand-storage" /tmp/p5.img 2>/dev/null | grep -q "Mode:  0755" && echo "p5 expand-storage exec OK"
  rm -f /tmp/p5.img
  minfo -i "$OUT@@$((P8_START * 512))" 2>/dev/null | grep -E "disk size|cluster size" | head -2
  ls -lh "$OUT"; du -h "$OUT"
'

echo
echo "Image: $OUT"
echo "Flash: diskutil unmountDisk /dev/diskN && sudo dd if=$OUT of=/dev/rdiskN bs=4m status=progress"
