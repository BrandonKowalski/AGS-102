#!/bin/sh
# Safely flash one target's BaseOS image to an SD card on macOS.
# Usage: ./flash-card.sh <target> [diskN]
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:?usage: $0 <target> [diskN]}"
python3 "$HERE/tools/device_profile.py" shell "$TARGET" >/dev/null
IMG="$HERE/work/$TARGET/baseos-$TARGET.img"
[ -f "$IMG" ] || { echo "missing $IMG (run build-image.sh $TARGET)"; exit 1; }
IMG_BYTES=$(stat -f %z "$IMG")

if [ $# -eq 1 ]; then
	echo "Removable candidates:"
	diskutil list external physical || true
	echo
	echo "Usage: $0 $TARGET diskN"
	exit 0
fi
[ "$#" -eq 2 ] || { echo "usage: $0 <target> [diskN]" >&2; exit 2; }

DISK="$2"
case "$DISK" in disk[0-9]|disk[0-9][0-9]) ;; *) echo "expected diskN, got '$DISK'"; exit 1 ;; esac

INFO="$(diskutil info "$DISK")"
echo "$INFO" | grep -qE "Protocol: +(USB|Secure Digital|SD Card Reader)|Device Location: +External" || {
	echo "REFUSING: $DISK does not look like an external/SD device"; exit 1; }
echo "$INFO" | grep -q "Internal: *Yes" && { echo "REFUSING: $DISK is internal"; exit 1; }

DISK_BYTES=$(echo "$INFO" | sed -n 's/.*Disk Size:.*(\([0-9]*\) Bytes.*/\1/p' | head -1)
[ -n "$DISK_BYTES" ] || { echo "cannot determine size of $DISK"; exit 1; }
[ "$DISK_BYTES" -ge "$IMG_BYTES" ] || {
	echo "REFUSING: $DISK ($DISK_BYTES B) is smaller than the image ($IMG_BYTES B)"; exit 1; }

echo "$INFO" | grep -E "Device Node|Media Name|Disk Size|Protocol"
echo "Image: $IMG"
echo
printf "This will DESTROY all data on /dev/%s. Type '%s' to continue: " "$DISK" "$DISK"
read -r CONFIRM
[ "$CONFIRM" = "$DISK" ] || { echo "aborted"; exit 1; }

diskutil unmountDisk "/dev/$DISK"
echo "Writing $(du -h "$IMG" | cut -f1) (apparent $((IMG_BYTES / 1024 / 1024)) MB)..."
sudo dd if="$IMG" of="/dev/r$DISK" bs=4m status=progress
sync
diskutil eject "/dev/$DISK" || true
echo "Done. Insert into the $TARGET TF1 slot and power on."
