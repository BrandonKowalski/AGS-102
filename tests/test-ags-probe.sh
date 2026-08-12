#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/diagnostics/probe/ags-probe"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

mkdir -p "$TMP/sys/class/power_supply/axp2202-battery"
printf '1952000\n' > "$TMP/sys/class/power_supply/axp2202-battery/charge_counter"
printf '16\n'      > "$TMP/sys/class/power_supply/axp2202-battery/os_sleep"
mkdir -p "$TMP/sys/class/input/event0/device/power"
printf 'axp2202-pek\n' > "$TMP/sys/class/input/event0/name"
printf 'disabled\n'    > "$TMP/sys/class/input/event0/device/power/wakeup"
mkdir -p "$TMP/sys/class/rtc/rtc0"
printf '0\n' > "$TMP/sys/class/rtc/rtc0/wakealarm"
mkdir -p "$TMP/proc"
printf 'root=/dev/mmcblk0p5 rootwait quiet splash init=/init\n' > "$TMP/proc/cmdline"
printf 'Linux version 4.9.170\n' > "$TMP/proc/version"
printf ' 31:  gpio  sunxi-hall\n' > "$TMP/proc/interrupts"

OUT="$TMP/probe.txt"
AGS_PROBE_OUT="$OUT" AGS_SYS="$TMP/sys" AGS_PROC="$TMP/proc" \
	AGS_ENV_PART="$TMP/nonexistent-partition" sh "$SCRIPT"

for section in CMDLINE KERNEL "POWER SUPPLY" INPUT WAKEUP INTERRUPTS RTC DISPDBG DMESG "UBOOT ENV"; do
	if ! grep -q "===== $section =====" "$OUT"; then
		echo "missing section: $section" >&2
		exit 1
	fi
done

# The values have to actually land, not just the headings.
grep -q 'quiet splash' "$OUT" || { echo "cmdline not captured" >&2; exit 1; }
grep -q 'os_sleep' "$OUT"     || { echo "os_sleep not captured" >&2; exit 1; }
grep -q 'axp2202-pek' "$OUT"  || { echo "input name not captured" >&2; exit 1; }
grep -q 'sunxi-hall' "$OUT"   || { echo "hall interrupt not captured" >&2; exit 1; }

# An absent env partition, an absent debugfs and an absent dmesg are all normal
# on a board nobody has characterised. The probe must record the absence and
# keep going: a probe that aborts halfway is worth less than a partial one.
if ! AGS_PROBE_OUT="$TMP/bare.txt" AGS_SYS="$TMP/empty" AGS_PROC="$TMP/empty" \
	AGS_ENV_PART="$TMP/nonexistent-partition" sh "$SCRIPT"; then
	echo "probe failed on a board with nothing present" >&2
	exit 1
fi
grep -q '===== UBOOT ENV =====' "$TMP/bare.txt" \
	|| { echo "bare probe stopped early" >&2; exit 1; }

echo "ags-probe tests passed"
