#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

mkdir -p "$TMP/zones/Etc" "$TMP/zones/Europe" "$TMP/data" "$TMP/run"
: > "$TMP/zones/Etc/UTC"
: > "$TMP/zones/Europe/Berlin"
printf '%s\n' \
	'#!/bin/sh' \
	'printf "%s\n" "$1" >> "$BASEOS_NTP_TEST_EVENTS"' \
	> "$TMP/ntp-helper"
chmod 755 "$TMP/ntp-helper"

run_timedatectl() {
	BASEOS_ZONEINFO_DIR="$TMP/zones" \
	BASEOS_DATA_DIR="$TMP/data" \
	BASEOS_LOCALTIME_LINK="$TMP/run/localtime" \
	BASEOS_NTP_STATE_FILE="$TMP/data/ntp-enabled" \
	BASEOS_NTP_SYNC_FILE="$TMP/run/ntp-synchronized" \
	BASEOS_NTP_HELPER="$TMP/ntp-helper" \
	BASEOS_NTP_LOG="$TMP/ntp.log" \
	BASEOS_NTP_TEST_EVENTS="$TMP/ntp-events" \
		sh "$HERE/overlay/usr/bin/timedatectl" "$@"
}

[ "$(run_timedatectl show -p Timezone --value)" = "Etc/UTC" ]
run_timedatectl set-timezone Europe/Berlin
[ "$(cat "$TMP/data/timezone")" = "Europe/Berlin" ]
[ "$(readlink "$TMP/run/localtime")" = "$TMP/zones/Europe/Berlin" ]
[ "$(run_timedatectl show --property Timezone --value)" = "Europe/Berlin" ]

rm -f "$TMP/run/localtime"
run_timedatectl apply
[ "$(readlink "$TMP/run/localtime")" = "$TMP/zones/Europe/Berlin" ]

if run_timedatectl set-timezone ../../etc/passwd 2>/dev/null; then
	echo "unsafe timezone was accepted" >&2
	exit 1
fi
[ "$(cat "$TMP/data/timezone")" = "Europe/Berlin" ]
[ "$(run_timedatectl show -p NTP --value)" = "no" ]
[ "$(run_timedatectl show -p NTPSynchronized --value)" = "no" ]

run_timedatectl set-ntp true
[ "$(cat "$TMP/data/ntp-enabled")" = "yes" ]
[ "$(run_timedatectl show -p NTP --value)" = "yes" ]
i=0
while ! grep -q '^run$' "$TMP/ntp-events" 2>/dev/null; do
	i=$((i + 1))
	[ "$i" -lt 20 ] || { echo "NTP helper did not start" >&2; exit 1; }
	sleep 0.05
done

# The boot-time apply path must restore the enabled preference by launching
# another detached helper invocation; duplicate suppression belongs to it.
run_timedatectl apply
i=0
while [ "$(grep -c '^run$' "$TMP/ntp-events")" -lt 2 ]; do
	i=$((i + 1))
	[ "$i" -lt 20 ] || { echo "boot apply did not restore NTP" >&2; exit 1; }
	sleep 0.05
done

: > "$TMP/run/ntp-synchronized"
[ "$(run_timedatectl show -p NTPSynchronized --value)" = "no" ]
printf '123\n' > "$TMP/run/ntp-synchronized"
[ "$(run_timedatectl show -p NTPSynchronized --value)" = "yes" ]

run_timedatectl set-ntp false
[ "$(cat "$TMP/data/ntp-enabled")" = "no" ]
[ "$(run_timedatectl show -p NTP --value)" = "no" ]
[ ! -e "$TMP/run/ntp-synchronized" ]
[ "$(tail -n 1 "$TMP/ntp-events")" = "stop" ]

if run_timedatectl set-ntp maybe 2>/dev/null; then
	echo "invalid NTP setting was accepted" >&2
	exit 1
fi
[ "$(cat "$TMP/data/ntp-enabled")" = "no" ]

echo "timedatectl compatibility tests passed"
