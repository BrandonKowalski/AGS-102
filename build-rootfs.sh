#!/bin/sh
# Assemble the minimal base OS rootfs from:
#   work/stock-harvest.tar  (capture-stock.sh)
#   work/tools/             (build-tools.sh: busybox, dropbearmulti)
#   overlay/                (our init + config)
# Output: work/rootfs.tar (root-owned, ready for mke2fs -d) + closure report.
# Everything that must execute aarch64 code (busybox --install, ldconfig,
# ld.so closure verification) runs in a native linux/arm64 container.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/work"

[ -f "$WORK/stock-harvest.tar" ] || { echo "missing $WORK/stock-harvest.tar (run capture-stock.sh)"; exit 1; }
[ -x "$WORK/tools/busybox" ] || { echo "missing $WORK/tools/busybox (run build-tools.sh)"; exit 1; }

docker run --rm --platform linux/arm64 \
  -v "$WORK":/work -v "$HERE/overlay":/overlay:ro -v "$HERE/assets":/assets:ro alpine:3.20 sh -euc '
  R=/tmp/rootfs
  rm -rf "$R"; mkdir -p "$R"

  ## 1. FHS skeleton with Ubuntu merged-usr symlinks (harvest paths assume it)
  mkdir -p "$R/usr/bin" "$R/usr/sbin" "$R/usr/lib" "$R/usr/libexec" "$R/usr/share"
  ln -s usr/bin "$R/bin"; ln -s usr/sbin "$R/sbin"; ln -s usr/lib "$R/lib"
  mkdir -p "$R/proc" "$R/sys" "$R/dev" "$R/tmp" "$R/run" "$R/var" "$R/data" \
           "$R/root" "$R/mnt/sdcard" "$R/mnt/vendor/bin" "$R/mnt/vendor/ctrl" \
           "$R/etc/init.d" "$R/media"
  chmod 700 "$R/root"; chmod 1777 "$R/tmp"

  ## 2. BusyBox first (harvest + overlay override applets where they overlap)
  cp /work/tools/busybox "$R/usr/bin/busybox"
  chroot "$R" /usr/bin/busybox --install -s
  # /init comes from the overlay as a regular staged-marker script (kernel
  # cmdline is init=/init; the vendor initramfs switch_roots into it)

  ## 3. Stock harvest on top
  tar -xf /work/stock-harvest.tar -C "$R"
  # alsa-lib plugin dir: drop static/libtool litter
  rm -f "$R"/usr/lib/aarch64-linux-gnu/alsa-lib/*.a "$R"/usr/lib/aarch64-linux-gnu/alsa-lib/*.la
  # flat module paths used by rcS / setBluetooth.sh
  ln -sf 4.9.170/kernel/drivers/net/wireless/rtl8821cs/8821cs.ko "$R/usr/lib/modules/8821cs.ko"
  ln -sf 4.9.170/kernel/drivers/bluetooth/rtl_btlpm.ko "$R/usr/lib/modules/rtl_btlpm.ko"
  # ELF interpreter compat path: every dynamic binary requests
  # /lib/ld-linux-aarch64.so.1 (resolves via the /lib -> usr/lib symlink)
  ln -sf aarch64-linux-gnu/ld-linux-aarch64.so.1 "$R/usr/lib/ld-linux-aarch64.so.1"
  # dev-name GLES symlinks (launch.sh probes libEGL.so before libEGL.so.1)
  ln -sf libEGL.so.1 "$R/usr/lib/libEGL.so"
  ln -sf libGLESv2.so.2 "$R/usr/lib/libGLESv2.so"

  ## 4. Our overlay wins over everything
  cp -R /overlay/. "$R/"
  chmod 755 "$R/init" \
            "$R/etc/init.d/rcS" "$R/etc/init.d/rcK" "$R/etc/init.d/dev" \
            "$R/usr/sbin/nextui-session" "$R/usr/sbin/systemctl" \
            "$R/usr/sbin/expand-storage" \
            "$R/mnt/vendor/ctrl/setBluetooth.sh" \
            "$R/usr/share/udhcpc/default.script"
  chmod 600 "$R/etc/shadow"
  # Guard: every boot-critical script must be executable (a non-exec script is
  # skipped by its `[ -x ]` guard and fails silently — cost us one flash).
  for s in /init /etc/init.d/rcS /etc/init.d/rcK /usr/sbin/nextui-session \
           /usr/sbin/expand-storage /usr/sbin/systemctl \
           /mnt/vendor/ctrl/setBluetooth.sh; do
    [ -x "$R$s" ] || { echo "FATAL: $s is not executable in rootfs"; exit 1; }
  done

  ## 5. Runtime-generated files live in /run; bake the symlinks
  ln -sf /run/resolv.conf "$R/etc/resolv.conf"
  ln -sf /run/machine-id "$R/etc/machine-id"
  ln -sf /proc/self/mounts "$R/etc/mtab"

  ## 6. Dropbear (dev flavour)
  cp /work/tools/dropbearmulti "$R/usr/sbin/dropbearmulti"
  for n in dropbear dropbearkey dbclient scp; do
    ln -sf dropbearmulti "$R/usr/sbin/$n"
  done
  ln -sf ../sbin/dropbearmulti "$R/usr/bin/scp"

  ## 6b. fbsplash boot splash (static) + its bundled Lexend font
  if [ -f /work/tools/fbsplash ]; then
    # busybox ships an fbsplash applet; drop its symlinks so ours is the only
    # fbsplash on PATH (usr/sbin precedes usr/bin), then install the real one.
    rm -f "$R/usr/sbin/fbsplash" "$R/usr/bin/fbsplash"
    cp /work/tools/fbsplash "$R/usr/bin/fbsplash"
    chmod 755 "$R/usr/bin/fbsplash"
    mkdir -p "$R/usr/share/baseos"
    cp /assets/boot.ttf "$R/usr/share/baseos/boot.ttf"
    [ -f /assets/OFL.txt ] && cp /assets/OFL.txt "$R/usr/share/baseos/boot.ttf.OFL.txt"
  fi
  # gptgrow: first-boot expand-to-fill of the FAT data partition.
  [ -f /work/tools/gptgrow ] && cp /work/tools/gptgrow "$R/usr/sbin/gptgrow" && chmod 755 "$R/usr/sbin/gptgrow"

  ## 7. ld.so.cache so the dynamic linker finds the multiarch dir
  chroot "$R" /usr/sbin/ldconfig || chroot "$R" /usr/sbin/ldconfig.real

  ## 8. Verify: every ELF in the tree resolves fully inside the tree
  LD="$R/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1"
  fail=0
  find "$R/usr/bin" "$R/usr/sbin" "$R/usr/libexec" -type f | while read -r f; do
    head -c4 "$f" | grep -q "^.ELF" || continue
    case "$f" in */busybox|*/dropbearmulti) continue ;; esac
    if ! chroot "$R" /usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 --list \
        "${f#"$R"}" 2>/dev/null | grep -q "=>"; then
      echo "UNRESOLVABLE: ${f#"$R"}"; fail=1
    fi
    chroot "$R" /usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 --list \
        "${f#"$R"}" 2>/dev/null | grep "not found" \
        | sed "s|^|MISSING for ${f#"$R"}: |" || true
  done > /tmp/closure-report.txt 2>&1 || true
  cp /tmp/closure-report.txt /work/closure-report.txt
  if grep -q MISSING /work/closure-report.txt; then
    echo "=== closure problems ==="; cat /work/closure-report.txt
  else
    echo "closure OK: all ELFs resolve in-tree"
  fi

  ## 9. Static console nodes: PID 1 needs them before devtmpfs is mounted
  ## (covers kernels without CONFIG_DEVTMPFS_MOUNT).
  mknod -m 600 "$R/dev/console" c 5 1
  mknod -m 666 "$R/dev/null" c 1 3

  ## 10. Ownership + pack
  chown -R 0:0 "$R"
  du -sh "$R"
  tar -C "$R" -cf /work/rootfs.tar .
'

ls -lh "$WORK/rootfs.tar"
echo "closure report: $WORK/closure-report.txt"
grep -c MISSING "$WORK/closure-report.txt" 2>/dev/null && echo "^ MISSING count (0 lines = good)" || echo "no MISSING entries"
