#!/bin/sh
# One-shot Super Standby measurement, run in place of the frontend's launch.sh.
#
# BaseOS execs this and expects it never to return, so the real launch.sh is
# exec'd at the end. It runs under init rather than adb, which is the whole
# point: every previous attempt at this measurement died because pulling the USB
# cable killed the adb session that was driving it.
#
# Armed by the presence of ags-sstest.pending, which is removed on the first
# run. Without that the device boots straight to the frontend as normal, so a
# forgotten install cannot leave the handheld suspending on every boot.
CARD=/mnt/sdcard
P=/sys/class/power_supply/axp2202-battery
U=/sys/class/power_supply/axp2202-usb/online
LOG="$CARD/ags-poweroff-test.txt"
FLAG="$CARD/ags-sstest.pending"

if [ -f "$FLAG" ]; then
	rm -f "$FLAG"
	sync

	# Super Standby. Write-only on this PMIC: it always reads back empty, so
	# there is no way to confirm it took other than by the result.
	printf 16 > "$P/os_sleep" 2>/dev/null

	# Never measure on the charger. usb_connecting wakes the device every
	# 20-40s while VBUS is present, and a charging cell cannot show a drain.
	n=0
	while [ "$(cat $U 2>/dev/null)" = "1" ] && [ "$n" -lt 60 ]; do
		sleep 1
		n=$((n + 1))
	done

	echo "SS-test before: counter=$(cat $P/charge_counter) cap=$(cat $P/capacity) status=$(cat $P/status) epoch=$(date +%s) uptime=$(cut -d' ' -f1 /proc/uptime) usb=$(cat $U)" >> "$LOG"
	sync

	echo mem > /sys/power/state

	# Reached only on resume. Stamped before the frontend starts so no frontend
	# activity is counted against the sleep.
	echo "SS-test after: counter=$(cat $P/charge_counter) cap=$(cat $P/capacity) status=$(cat $P/status) epoch=$(date +%s) uptime=$(cut -d' ' -f1 /proc/uptime)" >> "$LOG"
	sync
fi

exec /bin/sh "$(dirname "$0")/launch.real.sh"
