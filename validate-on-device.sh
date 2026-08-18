#!/bin/sh
# Post-flash functional validation for the base OS, run from the Mac against a
# booted device over adb.
#
# adb rather than ssh: adb runs over USB, needs no address, no password and no
# network, and is the only way onto a device with no console. The SSH server this
# product does ship is opt-in per card, so it cannot be assumed present on the
# device under test. Connect a data-capable USB-C cable before powering on.
#
# Usage: ./validate-on-device.sh <target> [adb-serial]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:?usage: validate-on-device.sh <target> [adb-serial]}"
SERIAL="${2:-}"
eval "$(python3 "$HERE/tools/device_profile.py" shell "$TARGET")"

command -v adb >/dev/null 2>&1 \
	|| { echo "adb is required (brew install android-platform-tools)" >&2; exit 1; }

# Every adb call carries the same target selection, so build it once.
if [ -n "$SERIAL" ]; then set -- -s "$SERIAL"; else set --; fi

adb "$@" get-state >/dev/null 2>&1 || {
	echo "no device over adb. Connect a data-capable USB-C cable and power on" >&2
	echo "with it attached; 'adb devices' should list the handheld." >&2
	exit 1
}

# The script is pushed and run rather than piped to `adb shell sh -s`: the adbd
# this OS ships (android-tools 4.2.2+git20130218) predates shell protocol v2, so
# stdin to a non-interactive shell is unreliable. That same vintage is why the
# device's exit status cannot come back over adb at all — the host sees adb's own
# status, not the command's — so the remote script prints a RESULT line and this
# side parses it. Old adbd also translates LF to CRLF, hence the tr.
LOCAL_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/baseos-validate.XXXXXX")"
trap 'rm -f "$LOCAL_SCRIPT"' EXIT
REMOTE_PATH=/tmp/baseos-validate.sh

{
	echo "BASEOS_EXPECTED_TARGET=$TARGET"
	echo "BASEOS_EXPECTED_WIFI=$PROFILE_WIFI"
	echo "BASEOS_EXPECTED_ROTATION=$PROFILE_PANEL_ROTATION_CCW"
	echo "BASEOS_EXPECTED_PANEL_WIDTH=$PROFILE_BOOTLOGO_WIDTH"
	echo "BASEOS_EXPECTED_PANEL_HEIGHT=$PROFILE_BOOTLOGO_HEIGHT"
	cat <<'REMOTE'
pass=0; fail=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }
chk()  { desc="$1"; shift; if eval "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

echo "=== identity ==="
chk "running the base OS (/etc/baseos-release)" "grep -q BASEOS=1 /etc/baseos-release"
chk "exact BaseOS target ($BASEOS_EXPECTED_TARGET)" "grep -qx BASEOS_TARGET=$BASEOS_EXPECTED_TARGET /etc/baseos-release"
chk "no systemd running"                        "! pidof systemd"
chk "busybox is init (PID 1)"                   "grep -q busybox /proc/1/comm || readlink /proc/1/exe | grep -q busybox"
chk "release version recorded"                  "grep -q '^BASEOS_VERSION=' /etc/baseos-release"
chk "os-release agrees with baseos-release"     "grep -qx \"VERSION_ID=\$(sed -n 's/^BASEOS_VERSION=//p' /etc/baseos-release)\" /etc/os-release"

echo "=== partition layout & update slots ==="
chk "seven partitions, not eight"       "test \"\$(grep -c 'mmcblk0p' /proc/partitions)\" -eq 7"
chk "U-Boot saw the BaseOS names"       "grep -q 'rootfs@mmcblk0p5:UDISK@mmcblk0p6:primary@mmcblk0p7' /proc/cmdline"
chk "/data is the UDISK partition (p6)" "grep -q '^/dev/mmcblk0p6 /data ' /proc/mounts"
chk "gptslot accepts this layout"       "/usr/sbin/gptslot /dev/mmcblk0 geometry"
chk "update engine present"             "test -x /usr/sbin/baseos-update"
/usr/sbin/gptslot /dev/mmcblk0 geometry 2>/dev/null | sed 's/^/  /'
/usr/sbin/baseos-update status 2>/dev/null | sed 's/^/  /'

echo "=== boot speed ==="
for m in rcS-start rcS-done frontend-exec dev-done adb-gadget-done; do
	if [ -f /run/boot-$m ]; then echo "  boot-$m: $(cat /run/boot-$m)s"; else echo "  boot-$m: (absent)"; fi
done
chk "frontend exec marker exists" "test -f /run/boot-frontend-exec"
if [ "$BASEOS_EXPECTED_TARGET" = rg40xxv ]; then
	chk "regular boot stays within the measured 3.00s frontend-exec budget" \
		"awk 'NR == 1 { exit !(\$1 <= 3.00) }' /run/boot-frontend-exec"
fi

echo "=== hardware ==="
chk "GPU module loaded (mali_kbase)"   "grep -q mali_kbase /proc/modules"
chk "GPU device node (/dev/mali0)"     "test -c /dev/mali0"
chk "display (/dev/disp + fb0)"        "test -c /dev/disp && test -c /dev/fb0"
# The splash and the bootlogo are both generated from the profile's panel
# dimensions, so a device that reports something else would render pre-turned
# artwork for a geometry it does not have. Only the width is compared: yres_virtual
# is several buffers deep for scanout, so the height is checked as a multiple.
chk "panel width matches the profile ($BASEOS_EXPECTED_PANEL_WIDTH)" \
	"test \"\$(cut -d, -f1 /sys/class/graphics/fb0/virtual_size)\" -eq $BASEOS_EXPECTED_PANEL_WIDTH"
chk "panel height is a whole number of $BASEOS_EXPECTED_PANEL_HEIGHT-row buffers" \
	"test \"\$(( \$(cut -d, -f2 /sys/class/graphics/fb0/virtual_size) % $BASEOS_EXPECTED_PANEL_HEIGHT ))\" -eq 0"
chk "splash knows the panel rotation ($BASEOS_EXPECTED_ROTATION ccw)" \
	"grep -qx BASEOS_PANEL_ROTATION_CCW=$BASEOS_EXPECTED_ROTATION /etc/baseos-release"
chk "HDMI hotplug state readable"      "test -r /sys/class/extcon/hdmi/state"
chk "display output switch (dispdbg)"  "test -w /sys/kernel/debug/dispdbg/command"
chk "input devices (event0-2)"         "test -c /dev/input/event0 && test -c /dev/input/event1"
chk "audio card 0 (audiocodec)"        "grep -q audiocodec /proc/asound/cards"
chk "battery sysfs (AXP2202)"          "test -r /sys/class/power_supply/axp2202-battery/capacity"
chk "thermal zones"                    "test -r /sys/class/thermal/thermal_zone0/temp"
chk "deep sleep available (mem)"       "grep -q mem /sys/power/state"
chk "rumble sysfs (moto)"              "test -w /sys/class/power_supply/axp2202-battery/moto"

echo "=== radios ==="
# The radios are opt-in via a card marker, so the correct expectation depends on
# whether the card asked for them — a loaded 8821cs on a card that did not is as
# much a failure as a missing one on a card that did.
if [ "$BASEOS_EXPECTED_WIFI" = 1 ] && { [ -f /mnt/sdcard/System/network.on ] || [ -f /mnt/sdcard/System/ssh.on ]; }; then
	chk "wifi module loaded (8821cs)"  "grep -q 8821cs /proc/modules"
	chk "wifi interface (wlan0)"       "test -d /sys/class/net/wlan0"
	# ssh.on implies a usable network, not merely a raised interface.
	if [ -f /mnt/sdcard/System/ssh.on ] && [ -f /mnt/sdcard/System/wifi.conf ]; then
		chk "wlan0 associated"     "wpa_cli -i wlan0 status 2>/dev/null | grep -q '^wpa_state=COMPLETED'"
		chk "wlan0 has an address" "ip -4 addr show wlan0 2>/dev/null | grep -q 'inet '"
	fi
else
	chk "wifi stays off (no System/network.on or ssh.on)" \
		"! grep -q 8821cs /proc/modules && ! test -d /sys/class/net/wlan0"
fi

echo "=== frontend ==="
chk "SD card mounted (/mnt/sdcard)"    "mountpoint -q /mnt/sdcard"
chk "slot running"                     "pidof slot"

echo "=== dev services ==="
# SSH ships in every image and starts for nobody who did not ask: a card needs
# System/ssh.on and an authorized_keys. Both halves are asserted, because a
# listener on a card that asked for neither is as much a failure as a missing one
# on a card that asked for both. The sftp helper stays gone - dropbear's own scp
# is inside the multi binary, and OpenSSH's child was 300 KB serving a subsystem
# nothing needs.
chk "SSH server shipped (static multi)" "test -x /usr/sbin/dropbearmulti && test -x /usr/sbin/dropbear"
chk "no OpenSSH sftp helper"            "! test -e /usr/libexec/sftp-server"
if [ -f /mnt/sdcard/System/ssh.on ] && [ -s /root/.ssh/authorized_keys ]; then
	chk "sshd listening on TCP 22"     "netstat -lnt 2>/dev/null | grep -q ':22 '"
	# The one flag that matters: root has no password, so password auth would be
	# blank-password auth. Read it off the running process, not off the script.
	chk "sshd refuses password auth"   'tr "\0" " " < /proc/$(pidof dropbear | cut -d" " -f1)/cmdline | grep -q " -s "'
	chk "authorized_keys is 0600"      'test "$(stat -c %a /root/.ssh/authorized_keys)" = 600'
else
	chk "sshd stays off (no System/ssh.on)" "! netstat -lnt 2>/dev/null | grep -q ':22 '"
fi
chk "adbd running"                      "pidof adbd"
chk "adb has no TCP 5555 listener"      "! netstat -lnt 2>/dev/null | grep -q ':5555 '"
# The adb gadget is bound to the always-present UDC; device (peripheral) mode is
# auto-selected by the sunxi manager on cable attach. We deliberately do NOT
# force usbc0/otg_role — writing it wedges the writer in D-state on this vendor
# kernel, and its siblings usb_device/usb_host/usb_null are read-triggers that
# switch the role on cat. So the check is "gadget bound", not "role == device".
chk "adb gadget bound (g1/UDC)"         "test -s /sys/kernel/config/usb_gadget/g1/UDC"
chk "functionfs mounted"                "grep -q functionfs /proc/mounts"

echo "=== resources ==="
echo "  processes: $(ps | wc -l)"
free | awk "/Mem:/ {printf \"  RAM used: %d/%d MB\n\", (\$2-\$7)/1024, \$2/1024}" 2>/dev/null || free
echo "  rootfs: $(df -h / | tail -1 | awk "{print \$3\" used, ro=\"}")$(grep " / " /proc/mounts | grep -o "[[:space:]]ro[,[:space:]]" | head -1)"
for z in 0 1 3; do
	t=$(cat /sys/class/thermal/thermal_zone$z/temp 2>/dev/null)
	[ -n "$t" ] && echo "  thermal_zone$z: $((t / 1000))°C"
done

echo
echo "=== RESULT: $pass passed, $fail failed ==="
REMOTE
} > "$LOCAL_SCRIPT"

adb "$@" push "$LOCAL_SCRIPT" "$REMOTE_PATH" >/dev/null 2>&1 \
	|| { echo "could not push the validation script to the device" >&2; exit 1; }
OUTPUT="$(adb "$@" shell sh "$REMOTE_PATH" | tr -d '\r')"
adb "$@" shell rm -f "$REMOTE_PATH" >/dev/null 2>&1 || true

printf '%s\n' "$OUTPUT"

FAILED="$(printf '%s\n' "$OUTPUT" | sed -n 's/^=== RESULT: [0-9]* passed, \([0-9]*\) failed ===$/\1/p')"
[ -n "$FAILED" ] || {
	echo >&2
	echo "validation did not run to completion on the device (no RESULT line)" >&2
	exit 1
}
exit "$FAILED"
