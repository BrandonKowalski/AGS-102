# 05 — Runtime: boot timing, power/sleep, network

All numbers here were measured on the RG40XXV running base OS (2026-07-19), not
estimated.

## 1. Boot timing (measured)

Kernel-relative markers are written to `/run/boot-*` by `rcS` / `nextui-session`
(seconds since kernel start):

| marker | warm boot | meaning |
|---|---|---|
| `boot-rcS-start` | 2.04 s | our init reached the first breadcrumb (proc/sys/dev/tmpfs mounted) |
| `boot-rcS-done` | 2.59 s | modules requested, `/data` + card mounted (~0.55 s of rcS) |
| `boot-frontend-exec` | 2.80 s | `launch.sh` handed control to NextUI |
| `boot-dev-done` | TBD | `/etc/init.d/dev` finished starting dropbear + launching the adb gadget script |
| `boot-adb-gadget-done` | TBD | the adb gadget bound its UDC (off the critical path — see §6) |

> The `dev` / `adb-gadget` markers are **measured per release**: they sit off the
> critical path (§6) and are re-measured, not carried forward, whenever that area
> changes. `validate-on-device.sh` prints them on every run.

The normal splash policy has no runtime detection, hashing, renderer process or
framebuffer write. It removes the former synchronous `/init` draw plus the routine
`rcS`/hand-off draws, so the expected regular-boot impact is non-positive by
construction—not merely assumed from a desktop benchmark. `boot-frontend-exec`
remains the on-device acceptance marker. The 2.80 s result above is the historical
reference; when the surrounding image state changes, use a controlled old/new A/B
before attributing movement to splash policy. On RG40XXV, `validate-on-device.sh`
fails above the current measured 3.00 s ceiling.

### Static-logo A/B (2026-07-24)

The first post-change boot measured 2.95 s and appeared to regress against the
historical 2.80 s result above. A controlled on-device A/B restored the exact
pre-change files from backup between reboots:

| build | `rcS-start` samples | `rcS-done` samples | `frontend-exec` samples | mean hand-off |
|---|---|---|---|---|
| pre-change animated splash | 2.08, 2.10 s | 3.00, 2.98 s | 3.01, 3.01 s | 3.01 s |
| static logo + exceptional pills | 1.99, 2.04, 2.05 s | 2.94, 2.95, 2.96 s | 2.95, 2.96, 2.97 s | 2.96 s |

The new policy is about **50 ms faster** at frontend hand-off and reaches `rcS`
roughly 60 ms earlier by removing the synchronous `/init` draw. The current device
state is slower than the older 2.80 s measurement for reasons that predate this
change—the old files reproduce the slowdown—so 3.00 s is the evidence-based
regression ceiling for this image state.

Then `launch.sh` + `nextui.elf` init add ~1–2 s to the first frame. Before the kernel,
boot0 + U-Boot add ~1.5–2.5 s (not software-visible; `bootdelay=0`).

**Stopwatch cold boot: 7.18 s** power-on → NextUI (vs ~15–20 s on stock). The stock
kernel eats the fixed first ~2 s and is untouchable here (rebuilding it is the
separate NextOS project). The `mali_kbase` background-load optimisation (below) shaved
frontend-exec from 3.04 s → 2.80 s.

### `mali_kbase` background load

`mali_kbase.ko` costs ~0.73 s to insmod, but nothing needs the GPU until NextUI's
`GFX_init` ~2 s later. `rcS` loads it in the **background** so it overlaps the card
mount and `launch.sh` startup; `nextui-session` waits (bounded) for `/dev/mali0`
before the hand-off. Measured: the wait was 0.1 s — almost the entire GPU load is now
hidden. Idle system: **74 MB RAM used / 973 MB**, rootfs 105 MB, CPU 44–45 °C at
`schedutil`.

## 2. Deep sleep — validated real, on hardware

The headline goal. Confirmed genuine **suspend-to-RAM**, not fake/freeze sleep, from
the kernel log after a real sleep/wake cycle:

```
PM: suspend entry ... 14:22:28
PM: Suspending system (mem)
PM: suspend of devices complete after 923.702 msecs
Disabling non-boot CPUs ...
Enabling non-boot CPUs ...
PM: suspend exit ...  14:58:01
```

`PM: Suspending system (mem)` = real STR (the thing mainline H616 / ROCKNIX can't do —
they ship fake suspend). `Disabling non-boot CPUs` = the other 3 cores actually
powered down. Over the **35.5-minute** sleep the AXP2202 coulomb counter
(`charge_counter`) **did not move** (1,952,000 µAh → 1,952,000 µAh, 61 % → 61 %) — a
flat counter that fake sleep at tens of mA would have visibly drained. This runs on an
OS we fully control, with no stock trampoline.

The suspend mechanism is unchanged from the port: `.system/h700/bin/suspend` echoes
`mem` to `/sys/power/state` directly (no systemd involvement); AXP2202 power-button
wake, lid handling and the WiFi bounce all stay as shipped. `alsactl` (harvested)
saves/restores the mixer across sleep.

**Measuring exact standby µA** needs a longer sleep — the coulomb counter is coarse
(no tick over 35 min at this draw; `current_now` reads empty). `diagnostics/sleep-drain/`
provides `pre-sleep.d`/`post-resume.d` hooks that stamp `charge_counter` + RTC time at
the exact suspend/resume boundary and log the delta to `/mnt/sdcard/sleep-drain.log`;
leave the device asleep for hours to get a projected-standby figure. (Hook files must
end in `.sh` — NextUI's `run_hooks.sh` only executes `*.sh`.)

## 3. WiFi — Base OS owns the interface

The RTL8821CS module (`8821cs.ko`) triggers an **asynchronous** SDIO probe that creates
`wlan0` ~2 s after the insmod returns. If a frontend's boot-time wifi bring-up runs
before `wlan0` exists, its `ip link set wlan0 up` / `wpa_supplicant -i wlan0` silently
fail and WiFi never comes up until the user toggles it.

To keep this **independent of any frontend**, Base OS owns the `wlan0` interface itself:
`rcS` runs a background task that loads the module, **waits for `wlan0` to appear
(bounded), then `rfkill unblock` + `ip link set wlan0 up`** (`ip`/`rfkill` are BusyBox
applets). By the time a frontend wants WiFi, the interface is present and up, so the
frontend only has to run `wpa_supplicant`/DHCP on it — no race-hardening needed in the
frontend's own scripts.

> Note: `wlan0` appears at ~5 s on the current timing (module init is the slow part).
> A frontend that starts `wpa_supplicant` *very* early could still beat it; the robust
> guarantee is that Base OS brings the interface up as soon as hardware allows and does
> not depend on the frontend to wait. NextUI additionally waits for `wlan0` in its own
> `wifi_init.sh` (belt-and-suspenders), but Base OS no longer relies on that.

- **Power-save.** `rtw_power_mgnt=2` (driver default) — **identical to stock**, kept as
  correct for a handheld's battery. It causes intermittent ICMP latency (aggressive
- **Power-save.** `rtw_power_mgnt=2` (driver default) — **identical to stock**, kept as
  correct for a handheld's battery. It causes intermittent ICMP latency (aggressive
  pings from a host monitor flap), but the association is rock-solid; not a fault.
- DHCP: base OS uses BusyBox `udhcpc` (Ubuntu had `dhclient`); `wifi_init.sh` already
  prefers `dhclient` and falls back to `udhcpc`, and the `udhcpc` event script writes
  `/run/resolv.conf` (rootfs is otherwise rw but `/etc/resolv.conf` is a baked symlink
  into `/run`).

## 4. Bluetooth audio

Uses the harvested stock stack directly: `rtk_hciattach` attaches the RTL8821CS UART,
`bluetoothd` (BlueZ 5.66) runs under a base-OS `dbus-daemon` started by the
`systemctl` shim, and `bluealsa` provides the A2DP source. NextUI's `bt_init.sh` drives
it unchanged via the `setBluetooth.sh` shim ([01](01-rootfs-and-init.md) §7). Validated
as far as daemons-run on-device (chroot); full pairing/audio is on the hardware
to-do in [06](06-status-and-lessons.md).

## 5. Power button / poweroff

There is no `systemd-logind` on base OS. NextUI's `keymon` reads the power key
(event0, `axp2202-pek`) directly and writes `/tmp/poweroff` / `/tmp/reboot` sentinels
that `launch.sh` acts on; BusyBox init runs the poweroff/reboot. A **long-press powers
off in hardware** at the AXP2202 PMIC regardless of software — normal, expected
force-off behaviour.

## 6. USB gadget — adb and optional card storage

The single USB-C port is a charge port that also exposes a USB peripheral controller.
Base OS drives it as a Google adb gadget so a host can `adb shell`/`adb push`/`adb pull`
over the cable — **USB only, no TCP** by design (same root/no-auth dev posture as the
root/root dropbear; keeping it off the network avoids exposing an unauthenticated shell
over WiFi). `/usr/sbin/usb-gadget-adb` composes the gadget; it is launched **backgrounded
from `/etc/init.d/dev`** (itself already backgrounded off `rcS`, [01](01-rootfs-and-init.md) §5).

**Role: preserve stock dual-role OTG.** The USB-C port is shared between peripheral
access and intentional USB-host devices. BaseOS leaves the vendor DTB and sunxi
manager in their stock auto mode, binds its gadget to the always-present UDC
(`5100000.udc-controller`), and does **not** force the role at runtime. Every runtime
role interface is a trap on this vendor kernel (measured on rg40xxv,
[06](06-status-and-lessons.md) §3):

- Writing `/sys/.../usbc0/otg_role` (e.g. `echo usb_device > otg_role`) **wedges the
  writer in an uninterruptible D-state** — reproduced both with and without a gadget
  bound — so a boot script that wrote it would leak a stuck process and never bring adb
  up.
- The sibling files `usb_device`/`usb_host`/`usb_null` are 0400 **read-triggers** — a
  bare `cat` of one switches the role and can wedge the port.

The reliable peripheral-mode contract is therefore simple: connect the host cable
before powering on. The manager selects the role during boot, while leaving the port
available for USB-host peripherals on boots where no host cable is connected.
Charging remains PMIC-controlled. (The manager's real device path is
`/sys/devices/platform/soc/usbc0`, reached through the stable
`/sys/bus/platform/devices/usbc0` symlink — but the script needs neither.)

**configfs gadget layout.** The stock 4.9.170 kernel has `CONFIG_USB_CONFIGFS_F_FS=y`
built in, so no module is needed. The script builds, under
`/sys/kernel/config/usb_gadget/g1`:

- IDs `idVendor 0x18d1` / `idProduct 0x4e42` (Google / adb);
- `strings/0x409/serialnumber` from `androidboot.serialno` on the kernel cmdline
  (falls back to a constant if absent), plus manufacturer/product strings;
- one function `functions/ffs.adb`, a **FunctionFS** instance, linked into
  `configs/c.1`;
- the FunctionFS mount at `/dev/usb-ffs/adb`, where `adbd` opens `ep0` and writes its
  descriptors.

**Start + bind ordering.** The UDC bind is the last step and it only succeeds **after**
`adbd` has written its descriptors to `ep0`. So the script starts `adbd` (as root)
first, then **retries** writing the controller name into `g1/UDC`
(`/sys/class/udc/5100000.udc-controller`) until the bind takes. Binding before `adbd`
has populated ep0 fails with `EINVAL`; the retry loop closes that race without a fixed
sleep.

**Disconnect / reconnect.** The sunxi manager clears `g1/UDC` whenever VBUS drops.
BaseOS intentionally does not keep a watcher, poller, hotplug helper, or manual
rebinder for this partial recovery case: none can repair a later attach where the
manager selects host role, and forcing the role would compromise OTG support. If adb
is disconnected, power off and start again with the cable connected.

**User stance.** adb is on by default, matching SSH/SFTP, but is reachable only by a
physically connected USB data cable present during power-on; the daemon has no TCP
5555 fallback. Create `/data/no-adb` and reboot to disable it. No frontend setting is
required, keeping this OS-owned developer access independent of the installed
frontend.

**USB-storage maintenance mode.** The same kernel also has
`CONFIG_USB_CONFIGFS_MASS_STORAGE=y`, and adb and mass storage work together as
one composite gadget. They cannot safely share the frontend *filesystem* with a
running frontend, however: a writable FAT/exFAT volume must never be mounted by
BaseOS and a USB host at the same time.

Connect the host cable first, then hold MENU from power-on to select an exclusive,
one-boot maintenance mode. H700 DTBs label that built-in button's active-low line
`GPIO Key Menu`. The vendor
input driver advertises standard `BTN_MODE` but does not maintain the
`EVIOCGKEY` current-state bitmap, so the small `boot-menu-held` script queries
the physical level from the already-mounted GPIO debug view. It has no wait
window, input loop, compiled helper or resident process. rcS checks it before
mounting frontend storage. Whole TF2
(`/dev/mmcblk1`) wins when present so the host receives its real partition table
and every partition; otherwise TF1's data partition (`/dev/mmcblk0p7`) is
exported.

`usb-storage-mode` publishes only a device that was never mounted during this
boot. Both the selector and gadget reject a whole disk if *any* child partition
is mounted. Missing or busy devices fail closed into a normal boot.

`nextui-session` sees the runtime marker, does not remount the card or launch a
frontend, and waits for the gadget's bounded ready/failure result. A successful
bind paints one static `USB STORAGE: EJECT BEFORE RESTART` pill; failure paints
`USB STORAGE FAILED: POWER OFF`, avoiding unsafe card-removal advice while the
kernel may still hold the backing device. The gadget normally exposes both adb
and writable storage; `/data/no-adb` makes this storage-only. Eject on the host
and restart without MENU to return to the frontend.

**Boot-time stance.** A normal boot performs one non-blocking input-state probe
before mounting frontend storage; it has no wait loop or resident process. The
gadget script is backgrounded off the already-backgrounded `init.d/dev`, so it
never delays `frontend-exec`. The one-second TF2 enumeration allowance runs only
after a MENU-requested maintenance boot. Two measurement hooks make the cost
observable: the script writes `/run/boot-adb-gadget-done` when the UDC bind lands and
appends `adb gadget ready` to `/mnt/sdcard/baseos-boot.log`; `init.d/dev` writes
`/run/boot-dev-done` when it finishes. Because these live off the critical path, the
boot-timing table (§1) leaves them **TBD / measured per release** — re-measure and
record them whenever this area changes rather than trusting a stale number.
