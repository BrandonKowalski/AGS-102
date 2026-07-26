#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/overlay/usr/sbin/usb-storage-mode"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

prepare() {
	sd="$1"
	mounts="$2"
	run="$3"
	umount_program="$4"
	BASEOS_STORAGE_MOUNTPOINT="$sd" \
	BASEOS_PROC_MOUNTS="$mounts" \
	BASEOS_RUN_ROOT="$run" \
	BASEOS_UMOUNT="$umount_program" \
	BASEOS_STORAGE_TEST_MODE=1 \
		sh "$SCRIPT" prepare
}

SD="$TMP/card"
BACKING="$TMP/card-device"
MOUNTS="$TMP/mounts"
mkdir -p "$SD"
: > "$BACKING"
printf '%s %s vfat rw 0 0\n' "$BACKING" "$SD" > "$MOUNTS"

# Exact key, including the CRLF written by common Windows editors.
printf '# BaseOS settings\r\nUSB_STORAGE=1\r\n' > "$SD/BaseOS.conf"
prepare "$SD" "$MOUNTS" "$TMP/run-ok" /usr/bin/true
[ "$(cat "$TMP/run-ok/usb-storage-device")" = "$BACKING" ]
[ ! -e "$TMP/run-ok/usb-storage-device.pending" ]

# Disabled or misspelled values never unmount/publish a device.
printf 'USB_STORAGE=0\n' > "$SD/BaseOS.conf"
if prepare "$SD" "$MOUNTS" "$TMP/run-off" /usr/bin/true; then
	echo "USB_STORAGE=0 activated storage mode" >&2
	exit 1
fi
[ ! -e "$TMP/run-off/usb-storage-device" ]

printf 'USB_STORAGE = 1\n' > "$SD/BaseOS.conf"
if prepare "$SD" "$MOUNTS" "$TMP/run-invalid" /usr/bin/true; then
	echo "non-literal config activated storage mode" >&2
	exit 1
fi

# An unmount failure is fail-closed: no device is published to the gadget.
printf 'USB_STORAGE=1\n' > "$SD/BaseOS.conf"
if prepare "$SD" "$MOUNTS" "$TMP/run-busy" /usr/bin/false; then
	echo "failed unmount activated storage mode" >&2
	exit 1
fi
[ ! -e "$TMP/run-busy/usb-storage-device" ]
[ ! -e "$TMP/run-busy/usb-storage-device.pending" ]

# A stale/missing mount source is also a normal-boot no-op.
printf '%s %s vfat rw 0 0\n' "$TMP/missing-device" "$SD" > "$MOUNTS"
if prepare "$SD" "$MOUNTS" "$TMP/run-missing" /usr/bin/true; then
	echo "missing backing device activated storage mode" >&2
	exit 1
fi

echo "usb-storage-mode tests passed"
