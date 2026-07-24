#!/bin/sh
# Userspace boot smoke test: run the assembled rootfs as an initramfs under
# QEMU (generic aarch64 virt machine, Alpine linux-virt kernel) so busybox
# /init -> inittab -> rcS -> nextui-session executes for real. Hardware
# steps (insmod, /data ext4, SD mount, ttyS0 getty) fail gracefully by
# design; this validates the init plumbing, not the drivers.
# A test-only inittab line prints a marker once rcS has completed.
#
# The container runs on the *host* Docker platform so qemu-system-aarch64 is
# a native host binary. On Intel Macs this avoids nested emulation (arm64
# container under QEMU-user running qemu-system under TCG), which is too
# slow to reach the marker within the timeout. The guest kernel is always
# aarch64 linux-virt, downloaded from Alpine's aarch64 package index.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"
TARGET="${1:?usage: $0 <target>}"
[ "$#" -eq 1 ] || { echo "usage: $0 <target>" >&2; exit 2; }
python3 "$HERE/tools/device_profile.py" shell "$TARGET" >/dev/null
WORK="$HERE/work/$TARGET"
[ -f "$WORK/rootfs.tar" ] || { echo "missing $WORK/rootfs.tar (run build-rootfs.sh $TARGET)"; exit 1; }

docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$WORK":/work -e TARGET="$TARGET" alpine:3.20 sh -euc '
  apk add -q qemu-system-aarch64

  # Guest kernel must be aarch64 even when this container is amd64.
  . /etc/os-release
  ALPINE_REL=$(printf "%s" "$VERSION_ID" | cut -d. -f1,2)
  MIRROR="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_REL}/main/aarch64"
  cd /tmp
  wget -q -O APKINDEX.tar.gz "$MIRROR/APKINDEX.tar.gz"
  tar -xzf APKINDEX.tar.gz
  PKG=$(awk -F: "
    \$1==\"P\" && \$2==\"linux-virt\" {want=1; next}
    want && \$1==\"V\" {print \"linux-virt-\" \$2 \".apk\"; exit}
  " APKINDEX)
  [ -n "$PKG" ] || { echo "could not resolve aarch64 linux-virt package" >&2; exit 1; }
  wget -q "$MIRROR/$PKG"
  mkdir -p /tmp/aarch64-boot
  tar -xzf "$PKG" -C /tmp/aarch64-boot
  KERNEL=/tmp/aarch64-boot/boot/vmlinuz-virt
  [ -f "$KERNEL" ] || { echo "kernel missing from $PKG" >&2; exit 1; }

  R=/tmp/r; mkdir -p "$R"
  tar -xf /work/rootfs.tar -C "$R"
  echo "::once:/bin/sh -c \"echo BASEOS-USERSPACE-BOOT-OK-$TARGET > /dev/console\"" >> "$R/etc/inittab"
  (cd "$R" && find . | cpio -o -H newc 2>/dev/null | gzip -1) > /tmp/rootfs.cpio.gz

  timeout 60 qemu-system-aarch64 \
    -M virt -cpu cortex-a53 -smp 2 -m 512 \
    -kernel "$KERNEL" -initrd /tmp/rootfs.cpio.gz \
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
