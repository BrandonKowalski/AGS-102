#!/bin/sh
# One-shot "does the RTC alarm wake this board" measurement, installed in place of the
# frontend binary at System/slot, with the real one renamed to System/slot.real.
#
# It cannot be driven over adb. The cable is a wakeup source in its own right — a suspend
# attempted with VBUS present aborts before it even reaches `Suspending system (mem)` — and
# the adb session dies at the suspend anyway, taking the shell that was going to record the
# answer with it.
#
# Super Standby is explicitly cleared rather than merely not set: rcS writes os_sleep=16 on
# every boot, so "untouched" is not "off" here. With it on, an alarm armed for 45 s did not
# wake the device in 195 s — measured, and the reason this test exists is to find out whether
# that is Super Standby's doing or the board's.
CARD=/mnt/sdcard
P=/sys/class/power_supply/axp2202-battery
U=/sys/class/power_supply/axp2202-usb/online
R=/sys/class/rtc/rtc0
LOG="$CARD/ags-alarm-test.txt"
PENDING="$CARD/ags-alarmtest.pending"

if [ -f "$PENDING" ]; then
	rm -f "$PENDING"
	sync

	# Off, not absent. This is the whole variable under test.
	printf 0 > "$P/os_sleep" 2>/dev/null

	# Never on the charger: VBUS aborts the suspend outright, and the cable would be a
	# second thing able to wake it even if it did not.
	n=0
	while [ "$(cat $U 2>/dev/null)" = "1" ] && [ "$n" -lt 120 ]; do
		sleep 1
		n=$((n + 1))
	done

	echo 0 > "$R/wakealarm" 2>/dev/null
	start="$(cat $R/since_epoch 2>/dev/null)"
	echo "$((start + 60))" > "$R/wakealarm" 2>/dev/null
	echo "ALARM-TEST armed at $start for +60s, os_sleep cleared, usb=$(cat $U), waited=${n}s" >> "$LOG"
	sync

	echo mem > /sys/power/state

	end="$(cat $R/since_epoch 2>/dev/null)"
	echo 0 > "$R/wakealarm" 2>/dev/null
	# 60 or so means the alarm did it. Much more means a human did, and this board cannot
	# wake itself at all — which would put the whole standby escalation out of reach.
	echo "ALARM-TEST slept $((end - start))s" >> "$LOG"
	sync
fi

# ags-session execs System/slot directly — there is no pak indirection any more — so this
# script stands in for the binary and hands over to the real one it was renamed aside as.
exec "$(dirname "$0")/slot.real"
