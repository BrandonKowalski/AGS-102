#!/bin/sh
# Phase 0 card shim. BaseOS execs the frontend's launch.sh and expects it never
# to return, so this starts the instrumentation and then hands over with exec,
# preserving that contract exactly.
#
# Install by renaming the frontend's own launch.sh to launch.real.sh and
# dropping this in its place. It works for NextUI and for slot without
# modification, which matters because the same card gets used for both.
HERE="$(dirname "$0")"
CARD=/mnt/sdcard

if [ -x "$CARD/System/ags-sample" ]; then
	AGS_SAMPLE_LOG="$CARD/ags-power.csv" \
		"$CARD/System/ags-sample" loop >/dev/null 2>&1 &
fi

if [ -x "$CARD/System/ags-probe" ]; then
	AGS_PROBE_OUT="$CARD/ags-probe.txt" \
		"$CARD/System/ags-probe" >/dev/null 2>&1 || true
fi

exec /bin/sh "$HERE/launch.real.sh"
