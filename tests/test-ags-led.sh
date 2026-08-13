#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/overlay/usr/sbin/ags-led"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PSY="$TMP/psy"
mkdir -p "$PSY"
STATE="$TMP/state"

gauge() {
	printf '%s\n' "$1" > "$PSY/capacity"
	printf '%s\n' "$2" > "$PSY/status"
}

led() {
	AGS_PSY="$PSY" AGS_LED_STATE="$STATE" sh "$SCRIPT" "$@"
}

# work_led + lowpwr_led as one string, so a test reads as the pair of lights it
# is actually asserting about.
lights() {
	printf '%s/%s' "$(tr -d ' \n' < "$PSY/work_led")" "$(tr -d ' \n' < "$PSY/lowpwr_led")"
}

expect() {
	got="$(lights)"
	if [ "$got" != "$1" ]; then
		echo "$3: expected green/red = $1, got $got" >&2
		exit 1
	fi
}

# A healthy battery is green.
gauge 80 Discharging
led once
expect "1/0" "" "healthy battery"

# At or below the low threshold, red alone. The green light goes out rather than
# both being lit: one light at a time was the decision taken on hardware.
gauge 15 Discharging
led once
expect "0/1" "" "at the low threshold"

# Hysteresis. Once red, a reading inside the band keeps it red — without this the
# whole-percent gauge would strobe the lights at the boundary.
gauge 17 Discharging
led once
expect "0/1" "" "inside the hysteresis band, coming from red"

# ...and it only clears at CLEAR, not one percent above LOW.
gauge 20 Discharging
led once
expect "1/0" "" "at the clear threshold"

# Coming down from green, 16 is not yet low.
gauge 16 Discharging
led once
expect "1/0" "" "just above the low threshold, coming from green"

# A charging device is never red, however empty it is: the orange charge light
# is already saying what is happening and red beside it would be a lie.
gauge 3 Charging
led once
expect "1/0" "" "charging on an almost flat battery"

gauge 3 Full
led once
expect "1/0" "" "full"

# `off` darkens both, and deliberately does NOT forget the colour it was
# showing, so that a resume restores the right one.
gauge 5 Discharging
led once
expect "0/1" "" "flat and discharging"
remembered="$(cat "$STATE")"
led off
expect "0/0" "" "off"
if [ "$(cat "$STATE")" != "$remembered" ]; then
	echo "off forgot the remembered colour: $(cat "$STATE") != $remembered" >&2
	exit 1
fi
led once
expect "0/1" "" "restored after off"

# A board with no gauge, or one that will not parse, leaves the light alone. An
# absent battery node is not an occasion to start flashing red.
gauge 80 Discharging
led once
expect "1/0" "" "healthy, before the gauge breaks"
printf 'not-a-number\n' > "$PSY/capacity"
led once
expect "1/0" "" "unparseable gauge holds the last colour"
rm -f "$PSY/capacity"
led once
expect "1/0" "" "absent gauge holds the last colour"

# Re-assertion. The attributes are write-only, so nothing can read back what the
# light is really doing; if the driver or anything else darkens it, the only
# defence is to write the wanted colour again every tick regardless of whether
# the decision changed. Simulated by darkening the lights behind the script's
# back while its remembered colour still says green.
gauge 80 Discharging
led once
expect "1/0" "" "healthy, before interference"
printf '0\n' > "$PSY/work_led"
printf '0\n' > "$PSY/lowpwr_led"
led once
expect "1/0" "" "the light is re-asserted after being darkened externally"

# An unknown subcommand is a usage error rather than a silent no-op.
if led bogus 2>/dev/null; then
	echo "an unknown subcommand exited 0" >&2
	exit 1
fi

echo "ags-led tests passed"
