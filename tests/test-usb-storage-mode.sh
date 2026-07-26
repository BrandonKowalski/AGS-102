#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/overlay/usr/sbin/usb-storage-mode"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

MOUNTS="$TMP/mounts"
TF1="$TMP/dev/mmcblk0p7"
TF2="$TMP/dev/mmcblk1"
TF2P1="${TF2}p1"
mkdir -p "$TMP/dev"
: > "$TF1"
: > "$TF2"
: > "$TF2P1"

prepare() {
	run="$1"
	BASEOS_PROC_MOUNTS="$MOUNTS" \
	BASEOS_RUN_ROOT="$run" \
	BASEOS_STORAGE_TF1_DEVICE="$TF1" \
	BASEOS_STORAGE_TF2_DEVICE="$TF2" \
	BASEOS_STORAGE_TEST_MODE=1 \
		sh "$SCRIPT" prepare
}

# Whole TF2 wins without mounting any of its partitions.
: > "$MOUNTS"
prepare "$TMP/run-tf2"
[ "$(cat "$TMP/run-tf2/usb-storage-device")" = "$TF2" ]
[ ! -e "$TMP/run-tf2/usb-storage-device.pending" ]

# A mounted TF2 child fails closed rather than sharing a live filesystem.
printf '%sp2 %s/other vfat rw 0 0\n' "$TF2" "$TMP" > "$MOUNTS"
if prepare "$TMP/run-tf2-busy"; then
	echo "mounted TF2 child activated storage mode" >&2
	exit 1
fi
[ ! -e "$TMP/run-tf2-busy/usb-storage-device" ]

# With no TF2, TF1's data partition is selected.
rm "$TF2" "$TF2P1"
: > "$MOUNTS"
prepare "$TMP/run-tf1"
[ "$(cat "$TMP/run-tf1/usb-storage-device")" = "$TF1" ]

# An unexpectedly mounted TF1 data partition is refused too.
printf '%s %s vfat rw 0 0\n' "$TF1" "$TMP" > "$MOUNTS"
if prepare "$TMP/run-tf1-busy"; then
	echo "mounted TF1 data partition activated storage mode" >&2
	exit 1
fi

# An unreadable mount table must be treated as busy, never as evidence that the
# device is safe to share.
mv "$MOUNTS" "$MOUNTS.saved"
if prepare "$TMP/run-mounts-unknown"; then
	echo "unknown mount state activated storage mode" >&2
	exit 1
fi
mv "$MOUNTS.saved" "$MOUNTS"

# No available user-storage device is a normal-boot no-op.
rm "$TF1"
: > "$MOUNTS"
if prepare "$TMP/run-missing"; then
	echo "missing backing device activated storage mode" >&2
	exit 1
fi

echo "usb-storage-mode tests passed"
