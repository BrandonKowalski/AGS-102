#!/bin/sh
# One-shot "does poweroff work when unplugged" measurement, run in place of the
# frontend's launch.sh.
#
# T3 ran `poweroff` with the USB cable attached, because adb needs it. The H700
# community reports that shutting down while plugged in is precisely the broken
# case (knulli-cfw/distribution#472, #287), so that measurement may have been of
# the wrong thing. This runs the same command with VBUS already gone, which no
# adb-driven test can do.
#
# Two markers, because a power off has no resume to stamp from:
#   ags-offtest.pending  arms the test on this boot
#   ags-offtest.armed    tells the NEXT boot to stamp the far side of the gap
#
# The armed check comes first so the boot that follows the power off records its
# reading before anything else runs.
CARD=/mnt/sdcard
P=/sys/class/power_supply/axp2202-battery
U=/sys/class/power_supply/axp2202-usb/online
LOG="$CARD/ags-poweroff-test.txt"
PENDING="$CARD/ags-offtest.pending"
ARMED="$CARD/ags-offtest.armed"

if [ -f "$ARMED" ]; then
	rm -f "$ARMED"
	echo "OFF-test after: counter=$(cat $P/charge_counter) cap=$(cat $P/capacity) status=$(cat $P/status) epoch=$(date +%s) uptime=$(cut -d' ' -f1 /proc/uptime)" >> "$LOG"
	sync
fi

if [ -f "$PENDING" ]; then
	rm -f "$PENDING"
	sync

	# Never power off on the charger: that is the case under suspicion, and a
	# charging cell cannot show a drain either way.
	n=0
	while [ "$(cat $U 2>/dev/null)" = "1" ] && [ "$n" -lt 120 ]; do
		sleep 1
		n=$((n + 1))
	done

	echo "OFF-test before: counter=$(cat $P/charge_counter) cap=$(cat $P/capacity) status=$(cat $P/status) epoch=$(date +%s) usb=$(cat $U) waited=${n}s" >> "$LOG"
	touch "$ARMED"
	sync

	poweroff

	# Only reached if poweroff returned without powering anything off, which is
	# itself the answer. Give init time to act before falling through.
	sleep 30
fi

exec /bin/sh "$(dirname "$0")/launch.real.sh"
