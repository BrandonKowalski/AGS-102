#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

printf 'yes\n' > "$TMP/ntp-enabled"
printf '%s\n' \
	'#!/bin/sh' \
	'printf "%s\n" "$*" >> "$BASEOS_NTP_TEST_DAEMON_LOG"' \
	'trap "exit 0" HUP INT TERM' \
	'while :; do sleep 1; done' \
	> "$TMP/fake-ntpd"
chmod 755 "$TMP/fake-ntpd"

run_helper() {
	BASEOS_NTP_STATE_FILE="$TMP/ntp-enabled" \
	BASEOS_NTP_PID_FILE="$TMP/ntp.pid" \
	BASEOS_NTP_LOCK_DIR="$TMP/ntp.lock" \
	BASEOS_NTP_SYNC_FILE="$TMP/ntp-synchronized" \
	BASEOS_NTP_DAEMON="$TMP/fake-ntpd" \
	BASEOS_NTP_NOTIFY="$TMP/missing-notify" \
	BASEOS_NTP_SERVERS="one.example two.example" \
	BASEOS_NTP_RETRY_SECONDS=1 \
	BASEOS_NTP_SKIP_NETWORK_CHECK=1 \
	BASEOS_NTP_TEST_DAEMON_LOG="$TMP/daemon.log" \
		sh "$HERE/overlay/usr/sbin/baseos-ntp" "$@"
}

run_helper run &
supervisor_job="$!"

i=0
while [ ! -s "$TMP/daemon.log" ]; do
	i=$((i + 1))
	[ "$i" -lt 40 ] || { echo "fake ntpd did not start" >&2; exit 1; }
	sleep 0.05
done

supervisor_pid="$(cat "$TMP/ntp.pid")"
kill -0 "$supervisor_pid"
[ "$(cat "$TMP/daemon.log")" = "-n -p one.example -p two.example" ]

# A duplicate launch must exit without replacing the active supervisor.
run_helper run
[ "$(cat "$TMP/ntp.pid")" = "$supervisor_pid" ]
kill -0 "$supervisor_pid"

: > "$TMP/ntp-synchronized"
run_helper stop
wait "$supervisor_job"
[ ! -e "$TMP/ntp.pid" ]
[ ! -d "$TMP/ntp.lock" ]
[ ! -e "$TMP/ntp-synchronized" ]

printf 'no\n' > "$TMP/ntp-enabled"
: > "$TMP/daemon.log"
run_helper run
[ ! -s "$TMP/daemon.log" ]

BASEOS_NTP_SYNC_FILE="$TMP/ntp-synchronized" \
	sh "$HERE/overlay/usr/sbin/baseos-ntp-notify"
sync_value="$(cat "$TMP/ntp-synchronized")"
case "$sync_value" in
	""|*[!0-9]*) echo "invalid synchronization timestamp: $sync_value" >&2; exit 1 ;;
esac

echo "BaseOS NTP supervisor tests passed"
