# 08 — USB adb and H700 OTG investigation

This is the decision record for cable-based adb on H700 devices. It preserves the
hardware findings behind the deliberately small implementation in
`/usr/sbin/usb-gadget-adb` and `usb-gadget-watch`.

## Decision

Enable USB-only adb by default alongside BaseOS's existing SSH/SFTP service, with an
optional BaseOS-owned maintenance boot that exposes user storage as writable USB mass
storage. Hold MENU from power-on; a one-shot state query selects the mode before
the frontend card is mounted. It reads the DT-labelled active-low GPIO because
the vendor driver's evdev current-state bitmap is stale. Whole TF2 wins when
present, otherwise TF1 p7 is exported. No frontend setting, udev/mdev
dependency, DTB change, compiled helper, polling loop, timing window, or
USB-role override is added. `/data/no-adb` is the persistent adb opt-out.

The default behavior is the user-friendly one: connect a data-capable USB-C cable and
use `adb shell`, `adb push`, or `adb pull`. Unplugging and reconnecting should not
require a reboot or a handheld key combination. For writable storage, hold MENU while
powering on and keep it held until the storage message appears.

## Verified H700 hardware contract

The RG40XXV uses the vendor Linux 4.9.170 kernel. Its relevant built-in facilities
are:

- configfs USB gadgets and FunctionFS (`CONFIG_USB_CONFIGFS_F_FS=y`);
- UDC `5100000.udc-controller`;
- sunxi OTG manager at `/sys/devices/platform/soc/usbc0`, also exposed through
  `/sys/bus/platform/devices/usbc0`;
- dual-role USB-C wiring with PMU VBUS detection and no useful ID GPIO.

Knulli's published H700 device tree describes the same port arrangement, so a DTB
fork would add maintenance without fixing role selection.

The safe rule is: bind the configfs gadget to the always-present UDC and leave the
sunxi manager in auto mode. Never use its role-control sysfs files:

- writing `usbc0/otg_role` wedges the writer permanently in uninterruptible D-state;
- `usb_device`, `usb_host`, and `usb_null` are read-trigger controls, not status
  files, and merely reading them can switch or wedge the port;
- reading `otg_role` itself is safe for diagnosis, but BaseOS does not need it for
  normal operation.

Leaving role selection automatic also leaves charging behavior on the shared port
alone. On a marginal attach the vendor manager can still choose host role and source
VBUS; software cannot safely override that kernel decision, so reconnecting the cable
is the only safe recovery.

## Gadget and daemon

The configfs gadget contains one FunctionFS adb interface (`ff/42/01`) with Google
VID/PID `18d1:4e42`. A pinned, static Android 4.2.2 `adbd` is built with the Debian and
Buildroot non-Android patches plus two local policies:

- stay root, matching the current root/root development-access posture;
- remove the TCP 5555 transport fallback, leaving USB as the only externally
  reachable transport.

The daemon still owns its private smart socket on `127.0.0.1:5037`, so
`usb-gadget-adb` brings up loopback before launching it. The UDC bind is retried only
for a bounded interval because FunctionFS cannot bind until `adbd` has supplied its
descriptors.

## Why reconnect needs a listener

On every disconnect/VBUS drop, the vendor manager clears
`usb_gadget/g1/UDC`. The gadget tree, FunctionFS mount, and daemon remain, and writing
the UDC name back after reconnection re-enumerates immediately. A one-shot boot bind
therefore is insufficient.

The trigger options were measured rather than guessed:

| Trigger | Decision |
|---|---|
| bind once at boot | rejected: fails after the first unplug |
| key combination | rejected: hidden manual recovery is not user-friendly |
| periodic poll | rejected: adds a permanent timer wake |
| `/sbin/hotplug` | rejected: forks once per kernel uevent |
| blocking netlink listener | selected: event-driven, contained, and suspend-friendly |

During a 45-second idle sample the RG40XXV produced five
`power_supply/change` events, one about every 10.24 seconds. That rules out a global
hotplug shell on both process churn and design grounds. `usb-gadget-watch` is a
65 KiB static listener. It filters uevents in-process, reads `g1/UDC`, and only execs
the existing bounded `rebind` action when the value is empty.

The value must be read. Configfs attributes advertise a synthetic nonzero file size,
so shell `test -s g1/UDC` falsely reports “bound” after the manager has emptied it.
A cleared attribute also reads as a single newline rather than zero bytes; both the
shell and C listener therefore test for non-whitespace content.

## Product fit

This stays within BaseOS's role: it owns H700 hardware and exposes a dependable,
frontend-neutral system service, then disappears. The service is quiet, starts off
the frontend-critical boot path, has no UI, and is absent from the network. All
failure paths are bounded silent no-ops, and missing USB facilities do not delay boot
on another target.

The cost is explicit: the already-planned static `adbd` is about 3.4 MiB and the
reconnect watcher is 65 KiB plus one sleeping process. That is preferable to a global
device manager or a frontend coupling solely for one optional developer facility.

## Mass-storage mode

The vendor kernel has `CONFIG_USB_F_MASS_STORAGE=y` and
`CONFIG_USB_CONFIGFS_MASS_STORAGE=y`. Hardware probing with a disposable 16 MiB FAT
backing file proved that the RG40XXV and macOS enumerate one composite gadget as both
ADB and a writable “File-Stor Gadget” LUN. Root adb remained usable concurrently.

The real frontend volume is different from a disposable backing file: BaseOS normally
mounts and executes the frontend from it, so sharing it live would risk filesystem
corruption. Storage mode is therefore an exclusive maintenance boot:

1. the user holds MENU from power-on;
2. `boot-menu-held` reads the DT-labelled physical GPIO level because the
   vendor driver advertises standard `BTN_MODE` but does not keep
   `EVIOCGKEY` state current;
3. before mounting frontend storage, BaseOS chooses whole TF2 when present, otherwise
   TF1 p7;
4. only an existing, completely unmounted device is published to configfs;
5. the frontend stays stopped while the host owns the device;
6. the user ejects on the host and restarts without MENU.

Exporting whole TF2 lets the host see its real partition table, access every supported
partition, and deliberately repartition or format the removable card. TF1 remains
partition-backed: the running root and `/data` make whole-TF1 export unsafe without a
separate RAM-root recovery design.

Every unsafe state fails closed. A missing block device does nothing, and both the
selector and gadget reject a whole device when it or any `pN` child remains mounted.
`/data/no-adb` removes the FunctionFS function but leaves requested mass storage
available.

## Validation

Automated checks cover gadget composition, repeat setup, empty-UDC rebind, no gadget,
no UDC, production AArch64 compilation, and the watcher-to-script boundary.
`validate-on-device.sh` checks the daemon, watcher, FunctionFS mount, bound UDC, and
absence of a TCP 5555 listener. RG40XXV hardware validation completed:

1. initial enumeration and a root `adb shell` — passed;
2. 4 MiB push/pull with matching SHA-256 — passed;
3. vendor-equivalent UDC clear while the watcher was running — rebound and host adb
   recovered in under one second through the event loop;
4. physical unplug/replug and suspend/resume remain release-image acceptance checks;
5. charging state and boot-time markers remain release-image acceptance checks.

Mass-storage validation additionally covers MENU selection policy, TF2 whole-device
promotion, mounted-child and missing-device rejection, ADB+storage and storage-only
composition, concurrent host enumeration, and the visible maintenance state.
Real-card acceptance must verify
MENU-held detection, host write/eject/reboot for TF1 p7, and whole-card enumeration
with a backed-up multi-partition TF2.
