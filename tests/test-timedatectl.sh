#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

mkdir -p "$TMP/zones/Etc" "$TMP/zones/Europe" "$TMP/data" "$TMP/run"
: > "$TMP/zones/Etc/UTC"
: > "$TMP/zones/Europe/Berlin"

run_timedatectl() {
	BASEOS_ZONEINFO_DIR="$TMP/zones" \
	BASEOS_DATA_DIR="$TMP/data" \
	BASEOS_LOCALTIME_LINK="$TMP/run/localtime" \
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

echo "timedatectl compatibility tests passed"
