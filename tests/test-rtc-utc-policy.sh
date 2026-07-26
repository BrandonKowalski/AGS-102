#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"

# The RTC holds UTC: baseos-ntp-notify persists time with `hwclock -u -w`, and
# the kernel's hctosys reads it as UTC too. Busybox hwclock only agrees when it
# is told so — given neither -u nor an /etc/adjtime saying UTC, it falls back to
# localtime and skews the system clock by the zone offset. That failure is
# silent: the frontend just shows a plausible wrong time until ntpd corrects it
# minutes into the session, and only if the user enabled NTP and has WiFi. So
# pin the direction statically rather than waiting to spot it on a screen.
#
# Comments discuss hwclock and its flags; strip them so only code is judged.
calls="$(grep -rn "hwclock" "$HERE/overlay" | sed 's/#.*//' | grep "hwclock" || true)"

if [ -z "$calls" ]; then
	echo "no hwclock invocation in the overlay: the clock is never taken from the RTC" >&2
	exit 1
fi

# Every call states UTC. The check wants the canonical spellings (-u/--utc) and
# rejects a bundled -us, which keeps this greppable by the next reader.
offenders="$(printf '%s\n' "$calls" \
	| grep -Ev '(^|[[:space:]])(-u|--utc)([[:space:]]|$)' || true)"
if [ -n "$offenders" ]; then
	echo "hwclock invoked without -u (busybox then reads the RTC as localtime):" >&2
	printf '%s\n' "$offenders" >&2
	exit 1
fi

localtime_calls="$(printf '%s\n' "$calls" \
	| grep -E '(^|[[:space:]])(-l|--localtime)([[:space:]]|$)' || true)"
if [ -n "$localtime_calls" ]; then
	echo "hwclock invoked with -l: the RTC holds UTC, not local time:" >&2
	printf '%s\n' "$localtime_calls" >&2
	exit 1
fi

# rcS must still be the place the system clock is taken from the RTC. Dropping
# the line would leave the clock to whatever hctosys managed, which is the same
# class of silent breakage this test exists to catch.
rcs_read="$(sed 's/#.*//' "$HERE/overlay/etc/init.d/rcS" \
	| grep -E 'hwclock.*(^|[[:space:]])(-s|--hctosys)([[:space:]]|$)' || true)"
if [ -z "$rcs_read" ]; then
	echo "rcS no longer sets the system clock from the RTC" >&2
	exit 1
fi

# The textbook alternative to -u is an adjtime file whose third line reads UTC,
# and it is a trap here. This busybox is built with the FHS path, so it never
# opens /etc/adjtime; the path it does read, /var/lib/hwclock/adjtime, is on the
# tmpfs rcS mounts over /var and cannot survive a boot. A baked-in file would
# look like the fix while changing nothing, so refuse one outright.
baked="$(find "$HERE/overlay" -name adjtime 2>/dev/null || true)"
if [ -n "$baked" ]; then
	echo "overlay bakes an adjtime file, which this busybox never reads:" >&2
	printf '%s\n' "$baked" >&2
	exit 1
fi

echo "RTC UTC policy tests passed"
