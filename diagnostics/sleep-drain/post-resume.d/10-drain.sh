#!/bin/sh
# NextUI post-resume hook: compute suspend drain from the pre-sleep stamp.
# run_hooks.sh only runs *.sh files, hence the extension. charge_counter is a
# hardware coulomb counter (uAh) that keeps accumulating during suspend; date
# +%s is RTC-backed and advances during suspend. Their deltas over the sleep
# interval give average current and projected standby. Appends one line per
# wake to /mnt/sdcard/sleep-drain.log. Install to:
#   /mnt/sdcard/.userdata/h700/.hooks/post-resume.d/10-drain.sh
B=/sys/class/power_supply/axp2202-battery
S=/mnt/sdcard/.userdata/h700/.sleep-stamp
[ -f "$S" ] || exit 0
read q0 t0 c0 < "$S"
q1=$(cat $B/charge_counter); t1=$(date +%s); c1=$(cat $B/capacity)
dt=$((t1 - t0)); dq=$((q0 - q1))
[ "$dt" -gt 0 ] || exit 0
if [ "$dq" -gt 0 ]; then
	ua=$(( dq * 3600 / dt ))                             # average uA over suspend
	full=$(cat $B/charge_full 2>/dev/null || echo 0)
	h=0; [ "$ua" -gt 0 ] && h=$(( full / ua ))           # projected standby hours
	printf '%s slept=%ss dQ=%suAh cap=%s%%->%s%% avg=%suA proj_standby=%sh\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$dt" "$dq" "$c0" "$c1" "$ua" "$h" >> /mnt/sdcard/sleep-drain.log
else
	# Counter did not tick: drain is below its resolution over this interval.
	# Bound it: less than one count (well under 32 mAh / 1% cap) across dt.
	printf '%s slept=%ss dQ=0 (below counter resolution) cap=%s%%->%s%% deep-sleep-confirmed\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$dt" "$c0" "$c1" >> /mnt/sdcard/sleep-drain.log
fi
rm -f "$S"
