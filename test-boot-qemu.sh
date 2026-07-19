#!/bin/sh
# Userspace boot smoke test: run the assembled rootfs as an initramfs under
# QEMU (generic aarch64 virt machine, Alpine linux-virt kernel) so busybox
# /init -> inittab -> rcS -> nextui-session executes for real. Hardware
# steps (insmod, /data ext4, SD mount, ttyS0 getty) fail gracefully by
# design; this validates the init plumbing, not the drivers.
# A test-only inittab line prints a marker once rcS has completed.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:?usage: $0 <target>}"
[ "$#" -eq 1 ] || { echo "usage: $0 <target>" >&2; exit 2; }
python3 "$HERE/tools/device_profile.py" shell "$TARGET" >/dev/null
WORK="$HERE/work/$TARGET"
[ -f "$WORK/rootfs.tar" ] || { echo "missing $WORK/rootfs.tar (run build-rootfs.sh $TARGET)"; exit 1; }

docker run --rm --platform linux/arm64 -v "$WORK":/work -e TARGET="$TARGET" alpine:3.20 sh -euc '
  apk add -q qemu-system-aarch64 linux-virt
  R=/tmp/r; mkdir -p "$R"
  tar -xf /work/rootfs.tar -C "$R"
  echo "::once:/bin/sh -c \"echo BASEOS-USERSPACE-BOOT-OK-$TARGET > /dev/console\"" >> "$R/etc/inittab"
  (cd "$R" && find . | cpio -o -H newc 2>/dev/null | gzip -1) > /tmp/rootfs.cpio.gz

  timeout 60 qemu-system-aarch64 \
    -M virt -cpu cortex-a53 -smp 2 -m 512 \
    -kernel /boot/vmlinuz-virt -initrd /tmp/rootfs.cpio.gz \
    -append "rdinit=/init console=ttyAMA0 loglevel=4" \
    -nographic -no-reboot > /tmp/boot.log 2>&1 || true

  echo "=== userspace-relevant console lines ==="
  grep -aE "BASEOS|init|rcS|nextui|getty|panic|Kernel panic|not found|can.t" /tmp/boot.log | head -20 || true
  if grep -aq "BASEOS-USERSPACE-BOOT-OK-$TARGET" /tmp/boot.log; then
    echo "RESULT: PASS — $TARGET busybox init + inittab + rcS completed"
  else
    echo "RESULT: FAIL — marker not reached"; tail -20 /tmp/boot.log; exit 1
  fi
'
