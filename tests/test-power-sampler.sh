#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/diagnostics/power-sampler/ags-sample"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

mkdir -p "$TMP/psy"
printf '1952000\n' > "$TMP/psy/charge_counter"
printf '61\n'      > "$TMP/psy/capacity"
printf 'Discharging\n' > "$TMP/psy/status"
printf '3760.42 14000.00\n' > "$TMP/uptime"

LOG="$TMP/power.csv"
run() {
	AGS_PSY="$TMP/psy" AGS_UPTIME="$TMP/uptime" AGS_SAMPLE_LOG="$LOG" \
		sh "$SCRIPT" once
}

run
run

# The header is written once, not once per sample: the analyser reads this with
# csv.DictReader and a second header would parse as a data row with a string
# where the epoch belongs.
headers="$(grep -c '^epoch,' "$LOG")"
if [ "$headers" != "1" ]; then
	echo "expected exactly one header line, got $headers" >&2
	exit 1
fi

rows="$(grep -c '^[0-9]' "$LOG")"
if [ "$rows" != "2" ]; then
	echo "expected 2 data rows, got $rows" >&2
	exit 1
fi

# Column order is load-bearing for the analyser. Check the values, not just the
# count, so a reordering is caught here rather than as wrong milliamps later.
last="$(grep '^[0-9]' "$LOG" | tail -n 1)"
if ! echo "$last" | grep -q ',3760.42,1952000,61,Discharging$'; then
	echo "unexpected row shape: $last" >&2
	exit 1
fi

# A board without a coulomb counter must yield an empty column, not a failure.
# The RG SP has never been booted and is not promised to publish the same
# attributes the RG40XXV did.
rm -f "$TMP/psy/charge_counter"
run
last="$(grep '^[0-9]' "$LOG" | tail -n 1)"
if ! echo "$last" | grep -q ',3760.42,,61,Discharging$'; then
	echo "absent charge_counter did not yield an empty column: $last" >&2
	exit 1
fi

echo "power sampler tests passed"
