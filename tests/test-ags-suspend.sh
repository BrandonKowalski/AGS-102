#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/overlay/usr/sbin/ags-suspend"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# A fake tree. Writing `mem` to a file returns immediately rather than suspending, which is
# what makes the far side of the sleep reachable from a test at all.
setup() {
	rm -rf "$TMP/sys" "$TMP/psy" "$TMP/led.log"
	mkdir -p "$TMP/sys/power" "$TMP/psy"
	: > "$TMP/sys/power/state"
	: > "$TMP/psy/os_sleep"
	cat > "$TMP/ags-led" <<-SH
		#!/bin/sh
		echo "\$1" >> "$TMP/led.log"
	SH
	chmod +x "$TMP/ags-led"
	: > "$TMP/led.log"
}

run() {
	AGS_PSY="$TMP/psy" AGS_SYS="$TMP/sys" AGS_LED_BIN="$1" sh "$SCRIPT"
}

setup
run "$TMP/ags-led"

# It suspended at all. Everything else is decoration if this did not happen.
[ "$(cat "$TMP/sys/power/state")" = "mem" ] \
	|| { echo "did not write mem to /sys/power/state" >&2; exit 1; }

# Super Standby every time, which is the reason this is one door rather than something each
# caller has to remember: 141 mA against under 45.
[ "$(cat "$TMP/psy/os_sleep")" = "16" ] \
	|| { echo "Super Standby was not applied" >&2; exit 1; }

# Dark on the way in, lit on the way out, in that order. A light left on through a suspend
# costs a real fraction of the budget, and one left off through a wake reads as a device that
# did not come back.
[ "$(tr '\n' ' ' < "$TMP/led.log")" = "off once " ] \
	|| { echo "led sequence was [$(tr '\n' ' ' < "$TMP/led.log")], wanted [off once ]" >&2; exit 1; }

# A board with no power light is not a failed suspend. The exit status is this script's
# answer to its caller, not a report on what hardware happens to be fitted.
setup
run "$TMP/no-such-led"
[ "$(cat "$TMP/sys/power/state")" = "mem" ] \
	|| { echo "a board with no LED helper did not suspend" >&2; exit 1; }

echo "ags-suspend tests passed"
