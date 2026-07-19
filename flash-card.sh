#!/bin/sh
# Safely flash the base OS image to an SD card on macOS.
# Refuses internal/synthesized disks, checks size, and requires the operator
# to type the disk identifier back before writing.
#
# Usage: ./flash-card.sh [diskN]     (no argument: list candidates and exit)
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
IMG="$HERE/work/baseos-h700.img"
[ -f "$IMG" ] || { echo "missing $IMG (run build-image.sh)"; exit 1; }
IMG_BYTES=$(stat -f %z "$IMG")

if [ $# -lt 1 ]; then
	echo "Removable candidates:"
	diskutil list external physical || true
	echo
	echo "Usage: $0 diskN"
	exit 0
fi

DISK="$1"
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
echo
printf "This will DESTROY all data on /dev/%s. Type '%s' to continue: " "$DISK" "$DISK"
read -r CONFIRM
[ "$CONFIRM" = "$DISK" ] || { echo "aborted"; exit 1; }

diskutil unmountDisk "/dev/$DISK"
echo "Writing $(du -h "$IMG" | cut -f1) (sparse; apparent $((IMG_BYTES / 1024 / 1024)) MB)..."
sudo dd if="$IMG" of="/dev/r$DISK" bs=4m status=progress
sync
diskutil eject "/dev/$DISK" || true
echo "Done. Insert into the TF1 slot and power on."
