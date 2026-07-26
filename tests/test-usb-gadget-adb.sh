#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/overlay/usr/sbin/usb-gadget-adb"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Build a fake /sys tree: one UDC and an (empty) configfs usb_gadget dir. On
# macOS these are all just ordinary files/dirs, so the script's mkdir/echo
# against them work with no root and no Linux. Note the script deliberately does
# NOT touch usbc0/otg_role (writing it wedges the real vendor kernel), so the
# fake tree needs no role-manager node.
build_tree() {
	root="$1"
	mkdir -p "$root/class/udc/5100000.udc-controller" \
	         "$root/kernel/config/usb_gadget"
}

run_gadget() {
	sys="$1"
	shift
	BASEOS_SYS_ROOT="$sys" \
	BASEOS_FFS_DIR="$TMP/ffs" \
		sh "$SCRIPT" "$@"
}

run_storage_gadget() {
	sys="$1"
	backing="$2"
	disable_adb="${3:-}"
	BASEOS_SYS_ROOT="$sys" \
	BASEOS_FFS_DIR="$TMP/ffs" \
	BASEOS_STORAGE_DEVICE="$backing" \
	BASEOS_DISABLE_ADB="$disable_adb" \
		sh "$SCRIPT" setup
}

# --- Happy path (setup) ---------------------------------------------------
# No action arg defaults to setup, so the existing invocation still exercises
# the compose+bind path.
build_tree "$TMP/sys"
run_gadget "$TMP/sys"

G="$TMP/sys/kernel/config/usb_gadget/g1"

# Gadget attributes.
[ "$(cat "$G/idVendor")" = "0x18d1" ]
[ "$(cat "$G/idProduct")" = "0x4e42" ]
[ -s "$G/strings/0x409/serialnumber" ]
[ -s "$G/strings/0x409/manufacturer" ]
[ -s "$G/strings/0x409/product" ]
[ -d "$G/configs/c.1" ]
[ -d "$G/functions/ffs.adb" ]
[ -L "$G/configs/c.1/ffs.adb" ]

# Bound to the fake UDC.
[ "$(cat "$G/UDC")" = "5100000.udc-controller" ]

# --- Idempotent second run is a no-op -------------------------------------
# A bound gadget must be left untouched. Stamp a marker, re-run, confirm the
# gadget tree is byte-for-byte identical and the marker survives.
echo marker > "$G/strings/0x409/product"
before="$(find "$G" | sort; cat "$G/strings/0x409/product")"
run_gadget "$TMP/sys"
after="$(find "$G" | sort; cat "$G/strings/0x409/product")"
[ "$before" = "$after" ] || { echo "second run mutated the gadget" >&2; exit 1; }

# --- Rebind repopulates an unbound gadget ---------------------------------
# The sunxi manager clears g1/UDC on every disconnect. Simulate that (empty the
# UDC file on the composed gadget) then run the rebind action and confirm the
# UDC name is written back — this is what makes a replug re-enumerate.
: > "$G/UDC"
[ ! -s "$G/UDC" ] || { echo "failed to simulate unbind" >&2; exit 1; }
run_gadget "$TMP/sys" rebind
[ "$(cat "$G/UDC")" = "5100000.udc-controller" ] \
	|| { echo "rebind did not re-bind the unbound gadget" >&2; exit 1; }

# A gadget that is still bound must be left untouched by rebind (it must never
# write UDC while already bound — the kernel returns -EBUSY).
before="$(find "$G" | sort; cat "$G/UDC")"
run_gadget "$TMP/sys" rebind
after="$(find "$G" | sort; cat "$G/UDC")"
[ "$before" = "$after" ] || { echo "rebind mutated an already-bound gadget" >&2; exit 1; }

# --- Rebind with no gadget composed is a silent no-op ---------------------
# Before setup has ever run there is no g1; rebind must not compose anything.
build_tree "$TMP/sys3"
run_gadget "$TMP/sys3" rebind
[ ! -d "$TMP/sys3/kernel/config/usb_gadget/g1" ] \
	|| { echo "rebind composed a gadget from scratch" >&2; exit 1; }

# --- No UDC present exits 0 quickly ---------------------------------------
# An empty /sys (no udc, no configfs) must be a silent no-op.
mkdir -p "$TMP/sys2/class/udc"
run_gadget "$TMP/sys2"
[ ! -d "$TMP/sys2/kernel/config/usb_gadget/g1" ] \
	|| { echo "gadget composed with no UDC present" >&2; exit 1; }

# --- Composite adb + mass storage -----------------------------------------
# rcS supplies an already-unmounted block device in production. The fake-tree
# test uses an ordinary file and verifies that both functions share one config.
build_tree "$TMP/sys4"
: > "$TMP/card.img"
run_storage_gadget "$TMP/sys4" "$TMP/card.img"
G4="$TMP/sys4/kernel/config/usb_gadget/g1"
[ -L "$G4/configs/c.1/ffs.adb" ]
[ -L "$G4/configs/c.1/mass_storage.usb0" ]
[ "$(cat "$G4/functions/mass_storage.usb0/lun.0/file")" = "$TMP/card.img" ]
[ "$(cat "$G4/functions/mass_storage.usb0/lun.0/removable")" = 1 ]
[ "$(cat "$G4/configs/c.1/strings/0x409/configuration")" = "adb + usb storage" ]
[ "$(cat "$G4/UDC")" = "5100000.udc-controller" ]

# /data/no-adb disables only adb, not an explicitly selected storage mode.
build_tree "$TMP/sys5"
: > "$TMP/card2.img"
run_storage_gadget "$TMP/sys5" "$TMP/card2.img" 1
G5="$TMP/sys5/kernel/config/usb_gadget/g1"
[ ! -e "$G5/configs/c.1/ffs.adb" ]
[ -L "$G5/configs/c.1/mass_storage.usb0" ]
[ "$(cat "$G5/configs/c.1/strings/0x409/configuration")" = "usb storage" ]
[ "$(cat "$G5/UDC")" = "5100000.udc-controller" ]

# With adb disabled, an invalid storage backing must compose nothing.
build_tree "$TMP/sys6"
run_storage_gadget "$TMP/sys6" "$TMP/missing.img" 1
[ ! -d "$TMP/sys6/kernel/config/usb_gadget/g1" ] \
	|| { echo "gadget composed with no enabled valid function" >&2; exit 1; }

echo "usb-gadget-adb tests passed"
