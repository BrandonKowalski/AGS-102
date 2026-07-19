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
