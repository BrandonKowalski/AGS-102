#!/bin/sh
# Hardware demonstration without flashing: run the base OS userland on the
# live device. The device already runs the byte-identical kernel/boot chain
# our image ships, so stopping the stock frontend tree and running our rootfs
# (chroot) against the real display/GPU/audio/input demonstrates everything
# above the bootloader. Captures the framebuffer as proof, then reboots the
# device back to its normal state.
#
# Usage: ./demo-live-takeover.sh <device-ip> [password]
set -eu

IP="${1:?usage: demo-live-takeover.sh <device-ip> [password]}"
PW="${2:-root}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/work"
SSH="sshpass -p $PW ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 root@$IP"

[ -f "$WORK/rootfs.tar" ] || { echo "missing rootfs.tar"; exit 1; }

echo "== 1/5 push rootfs to device tmpfs"
$SSH 'rm -rf /tmp/baseos && mkdir -p /tmp/baseos && tar -xf - -C /tmp/baseos' < "$WORK/rootfs.tar"

echo "== 2/5 stop stock frontend tree (sshd stays up as recovery path)"
$SSH '
systemctl stop launcher.service custom-boot.service 2>/dev/null || true
for p in launch.sh nextui.elf minarch.elf keymon.elf batmon.elf audiomon.elf dmenu.bin show.elf; do
	killall "$p" 2>/dev/null || true
done
sleep 2
! pidof nextui.elf >/dev/null 2>&1 && echo "stock frontend stopped"'

echo "== 3/5 enter base OS userland (chroot) and start the NextUI session"
$SSH '
R=/tmp/baseos
mountpoint -q $R/proc || mount --bind /proc $R/proc
mountpoint -q $R/sys  || mount --bind /sys  $R/sys
mountpoint -q $R/dev  || mount --bind /dev  $R/dev
mountpoint -q $R/dev/pts || mount --bind /dev/pts $R/dev/pts
mount -t tmpfs tmpfs $R/tmp 2>/dev/null || true
mount -t tmpfs tmpfs $R/run 2>/dev/null || true
mount -t tmpfs tmpfs $R/var 2>/dev/null || true
mkdir -p $R/run/dbus $R/var/lib $R/var/log $R/var/lib/alsa $R/var/lib/bluealsa
ln -sf /run $R/var/run 2>/dev/null || true
chroot $R /usr/bin/dbus-uuidgen > $R/run/machine-id
mkdir -p $R/mnt/sdcard
mountpoint -q $R/mnt/sdcard || mount --bind /mnt/sdcard $R/mnt/sdcard
# run our session exactly as busybox init would (respawn loop not needed for demo)
chroot $R /bin/sh -c "cut -d\" \" -f1 /proc/uptime > /run/boot-rcS-done; exec /sbin/nextui-session" \
	> /tmp/takeover-session.log 2>&1 &
echo "session started (pid $!)"'

echo "== 4/5 wait for NextUI, then verify"
sleep 20
$SSH '
if pidof nextui.elf >/dev/null; then echo "PASS: nextui.elf is RUNNING under the base OS rootfs"; else
	echo "FAIL: nextui.elf not running"; tail -30 /tmp/takeover-session.log /tmp/baseos/tmp/nextui-session.log 2>/dev/null; fi
pidof keymon.elf >/dev/null && echo "PASS: keymon running" || echo "note: keymon not detected"
ls -la /proc/$(pidof nextui.elf 2>/dev/null | cut -d" " -f1)/root 2>/dev/null | grep -o "baseos" | head -1 | sed "s/^/PASS: nextui root is /"'

echo "== capture framebuffer proof"
$SSH 'dd if=/dev/fb0 bs=1228800 count=1 2>/dev/null | gzip -1' > "$WORK/takeover-fb.raw.gz"
gunzip -f "$WORK/takeover-fb.raw.gz"
python3 - "$WORK/takeover-fb.raw" "$WORK/takeover-proof.png" <<'EOF'
import struct, sys, zlib
raw = open(sys.argv[1], 'rb').read()[:640*480*4]
rows = []
for y in range(480):
    row = bytearray()
    for x in range(640):
        b, g, r, a = raw[(y*640+x)*4:(y*640+x)*4+4]
        row += bytes((r, g, b))
    rows.append(bytes(row))
def chunk(t, d):
    c = t + d
    return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c))
ihdr = struct.pack('>IIBBBBB', 640, 480, 8, 2, 0, 0, 0)
idat = zlib.compress(b''.join(b'\x00' + r for r in rows), 6)
open(sys.argv[2], 'wb').write(
    b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', idat) + chunk(b'IEND', b''))
print("wrote", sys.argv[2])
EOF

echo "== 5/5 restore device to normal (reboot)"
$SSH 'sync; reboot' || true
echo "Proof image: $WORK/takeover-proof.png (device rebooting back to stock+NextUI)"
