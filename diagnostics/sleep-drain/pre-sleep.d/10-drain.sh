#!/bin/sh
# NextUI pre-sleep hook: stamp the coulomb counter + RTC time at the moment
# we enter suspend, so the paired post-resume hook can compute drain across
# the exact suspend/resume boundary. Install to:
#   /mnt/sdcard/.userdata/h700/.hooks/pre-sleep.d/10-drain
B=/sys/class/power_supply/axp2202-battery
echo "$(cat $B/charge_counter) $(date +%s) $(cat $B/capacity)" > /mnt/sdcard/.userdata/h700/.sleep-stamp
sync
