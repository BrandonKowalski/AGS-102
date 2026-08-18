# 2026-08-18 — charger boot, and a power off that stays off

Measured on the RG SP, serial `ac001089c8958701d12`, over adb, against BaseOS
1.1.0 with `slot` on the card. Started from a user report — *"BaseOS seems to
auto boot when powered off and a charger is plugged in"* — and ended with two
shipped changes and three of Phase 0's conclusions overturned.

| question | answer |
|---|---|
| why does plugging in boot the device | the PMIC powers the rails on VBUS; U-Boot flags it and BaseOS ignored the flag |
| can software tell it happened | yes — `bootreason=charger` on the cmdline, `boot_mode=1` in sysfs |
| does `poweroff` stay off on a charger | **no** through the kernel, **yes** written directly to the PMIC |
| is there a true off while charging | yes — the PMIC's 6 s long-press, and now software too |
| can a PC be told from a dumb charger | **no** — no `usb_type`, BC detect reads empty |

## 1. The charger boot is the PMIC, and U-Boot names it

Plugging a cable into a powered-off RG SP boots it. That is the AXP2202 bringing
up the rails when VBUS appears — vendor behaviour, not a fault, and not
suppressible from Linux. U-Boot records the cause on the kernel cmdline, and the
vendor driver mirrors it in sysfs:

| how it powered on | `/proc/cmdline` | `axp2202-battery/boot_mode` |
|---|---|---|
| POWER button | `bootreason=button` | `0` |
| cable inserted | `bootreason=charger` + `androidboot.mode=charger` | `1` |
| `reboot` | `bootreason=unknow` (vendor's spelling) | `0` |

All three confirmed on hardware. **`bootreason` tracks the power-on cause, not
VBUS presence** — pressing POWER with the cable already attached gives a
completely normal boot, which is what keeps adb usable and is why the charger
branch costs no access to the device.

Nothing in the OS read either signal, so a charger boot ran to `slot` and stayed
there. Caught live at 6% battery: `slot` running, `status=Charging`, the emulator
at full speed competing with the charger. knulli-cfw/distribution#287 is the same
fault on an RG35XX SP.

The vendor clearly intended a charging mode — p2 carries 21 images under `bat/`,
including an 11-frame animation (`bat0`–`bat10`, 120×250 24bpp), `battery_charge.bmp`,
plus `bat_htmp` / `bat_ltmp` / `low_pwr` / `bempty` for the too-hot, too-cold and
flat cases. U-Boot draws one of them on a charger boot before Linux starts, so
the cable already produces visible feedback with no work from us.

## 2. The kernel's power off does not stay off on a charger

The important measurement of the day, and it took three attempts to design
correctly.

| shutdown route | VBUS | result |
|---|---|---|
| `reboot(RB_POWER_OFF)` via `poweroff` | attached | **restarts in ~7 s** as `bootreason=charger` |
| `reboot(RB_POWER_OFF)` via `poweroff` | absent | stays off (Phase 0, T3 revised) |
| PMIC long-press, 6 s (POK/OFFLEVEL) | attached | stays off |
| **`REG27H[0]` written over i2c** | attached | **stays off** |

The restart is orderly, not a crash: `rcK` logs `START` and `DONE`, the frontend
exits, `mali_kbase` unloads, and the device comes back anyway. So this is not the
hang Phase 0 diagnosed — the shutdown completes and something undoes it.

Consequence, before the fix: `slot`'s doze timeout ends in `poweroff` after 300 s,
so any device left on a charger cycled every five minutes indefinitely.

## 3. What the PMIC registers say

The BSP calls this part AXP2202; it is the same silicon as the **AXP717**, whose
datasheet is public. Register map alignment confirmed three independent ways
before trusting it: `REG00[5]` (VBUS_GD) reads 1 with a charger attached;
`REG22H[1]` reads 1 matching the device tree's `pmu_powkey_off_en = 1`; and
`REG22H[0] = 0` predicts the long-press staying off, which it does.

**REG 27H "Soft Poweroff configure"** (datasheet 6.15.2.26). This device reads
**`0x08`**, against a POR default of `0x04` — *both* configurable bits inverted,
and reprogrammed by vendor firmware on every boot (a runtime write does not
survive a power cycle):

| bit | function | default | this device |
|---|---|---|---|
| 3 | PWROK pin pull low → restart the system | `0` disable | **`1` enabled** |
| 2 | PWRON 16 s → shutdown the PMIC | `1` enable | **`0` disabled** |
| 1 | restart the system (RWAC) | `0` | `0` |
| 0 | **soft PWROFF** (RWAC) | `0` | `0` |

`REG22H = 0x1e`, whose bit 0 decides whether the PMU auto-turns-on after an
OFFLEVEL POK shutdown. It reads `0`, and the long-press demonstrably stays off,
which establishes the polarity empirically: **0 = do not auto turn on**.

Bit 2 being disabled is worth remembering. The PMIC's 16-second emergency
shutdown is off on this hardware, which may be why the Phase 0 latch incident
survived an 8–10 second POWER hold and needed the battery disconnected.
Re-enabling it would restore a hard-off recovery path and is a return to the
chip's own default. **Untested.**

## 4. Two theories tested and killed

Recorded because both were plausible, and because the tests were cheap next to
the reasoning that produced them.

**PWROK restart (`REG27H[3]`) is innocent.** The obvious suspect: a
non-default-enabled "pull PWROK low to restart" bit, with the rails collapsing at
shutdown as the trigger. Cleared it over i2c and the device restarted anyway. It
also reverted to `0x08` on the next boot, which is how we learned the register is
reprogrammed every boot.

**OTP power-on source (5) is not firing.** The datasheet lists "battery is
charged to normal (VBAT>3.3 V and is charging)" as a power-on source, configurable
only "by customization" — i.e. OTP, unfixable in software. It fits the symptom
exactly and would have made the fault permanent. It is disproved by the PMIC
write staying off in precisely that condition: 3.8 V and charging.

The actual mechanism — what in PSCI `SYSTEM_OFF` → BL31 undoes the shutdown — was
never identified. It was **bypassed, not diagnosed.** Worth stating plainly so
nobody later assumes it is understood.

## 5. Corrections to Phase 0

Three conclusions in `2026-08-12-phase-0.md` are wrong or misleading:

- **"`poweroff` breaks when VBUS is present — *wrong*, the frontend was the one
  that mattered."** The retraction was itself wrong. VBUS presence *is* decisive,
  reproducibly, with the frontend killed and the GPU unloaded. The mechanism is
  not a hang, which is why the original framing looked wrong.
- **"400–700 mA after a `poweroff` with VBUS present."** Better explained by the
  device having rebooted and been running normally than by a wedged SoC with the
  rails up. "Off while plugged in" was not a state this board had, so any
  measurement of it was measuring a running device.
- **"There is no working software power off on this board" (amendment 12.1).**
  False. There is; it just is not the kernel's.

Not corrected, because today's evidence does not settle it: whether
`reboot(RB_POWER_OFF)` genuinely hangs on a live `mali_kbase`. No hang was
reproduced, but none was attempted either. `rcK`'s teardown is retained
regardless — the reboot path still walks every driver's `.shutdown()` hook, so
the argument for unloading the GPU is unchanged there.

## 6. What shipped

- `src/axp-off.c` — writes `REG27H[0]` over `/dev/i2c-5` (address 0x34,
  `I2C_SLAVE_FORCE`, since the driver holds it). Register is a compile-time
  constant, bit 1 masked off every write, `--now` required to arm.
- `overlay/usr/sbin/poweroff` — shim recording intent in `/run/poweroff-requested`.
  BusyBox init runs one `::shutdown:` action for both poweroff and reboot and
  gives no way to tell them apart; absent the marker, `rcK` takes the reboot path,
  because a poweroff that falls through merely restarts on the charger while a
  reboot that powers off strands `baseos-update` after a slot flip.
- `overlay/etc/init.d/rcK` — unmounts card and `/data` by name (`umount -a` would
  take devtmpfs and `/dev/i2c-5` with it), then cuts power at the PMIC.
- `overlay/etc/init.d/rcS` — ends a charger boot before `baseos-update boot-check`,
  guarded on a real `/data`, `/data/no-charger-off`, a usable RTC, and a 120 s
  loop window.

Exercised 11 `rcK` runs across both paths, including one through `slot`'s own
power menu with the GPU live, with no filesystem damage in any of them.

## 7. Three things that cost time

- **`wait-for-device` returns while the device is still shutting down.** It
  produced a false "it came back on its own" that inverted a result. Wait for
  disconnect first, then for reappearance, and verify by `/proc/uptime` rather
  than by adb presence.
- **The regmap cache covers only `0x79`–`0x9f`.** A stale-cache theory for why a
  register write reverted was wrong; `rbtree` in the regmap debugfs directory says
  exactly what is cached, and `0x27` is not.
- **`sync` is not an unmount.** The charger branch left `/data` mounted across the
  power cut and replayed its journal on every subsequent boot. Visible as
  `EXT4-fs (mmcblk0p6): recovery complete`, gone once the unmount was added.
