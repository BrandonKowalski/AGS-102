#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"
WATCHER="$HERE/work/tools/usb-gadget-watch"

[ -x "$WATCHER" ] \
	|| { echo "missing $WATCHER (run build-tools.sh)" >&2; exit 1; }

# The production binary is AArch64/Linux, so exercise it in the same
# architecture container used by the image build. --once drives the exact
# "is g1/UDC empty? then exec rebind" boundary without needing a real netlink
# socket or USB controller.
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
	-v "$HERE":/repo:ro alpine:3.20 sh -euc '
	T="$(mktemp -d)"
	trap "rm -rf \"$T\"" EXIT HUP INT TERM
	SCRIPT=/repo/overlay/usr/sbin/usb-gadget-adb
	WATCHER=/repo/work/tools/usb-gadget-watch

	mkdir -p "$T/sys/class/udc/5100000.udc-controller" \
		"$T/sys/kernel/config/usb_gadget"
	BASEOS_SYS_ROOT="$T/sys" BASEOS_FFS_DIR="$T/ffs" \
		sh "$SCRIPT" setup
	G="$T/sys/kernel/config/usb_gadget/g1"

	# A cleared configfs UDC attribute reads as one newline byte, not a
	# zero-length file. Match the real kernel rather than an ordinary empty file.
	printf "\n" > "$G/UDC"
	BASEOS_SYS_ROOT="$T/sys" BASEOS_FFS_DIR="$T/ffs" \
		BASEOS_REBIND_PROGRAM="$SCRIPT" "$WATCHER" --once
	[ "$(cat "$G/UDC")" = 5100000.udc-controller ] \
		|| { echo "watcher did not rebind an empty gadget" >&2; exit 1; }

	# With no composed gadget, startup is deliberately a silent no-op.
	mkdir -p "$T/empty"
	BASEOS_SYS_ROOT="$T/empty" BASEOS_REBIND_PROGRAM="$SCRIPT" \
		"$WATCHER" --once
'

echo "usb-gadget-watch tests passed"
