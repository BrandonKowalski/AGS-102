# 06 — Status, bug log & lessons

## 1. Hardware-validation matrix (RG40XXV, 2026-07-19)

| capability | status |
|---|---|
| Regenerated-GPT boot (boot0/U-Boot/kernel accept it) | ✅ on a 64 GB card |
| Minimal rootfs mounts + BusyBox init → NextUI | ✅ cold boot 7.18 s |
| First-boot expand-to-fill (FAT partition 68 MB → 62.8 GB) | ✅ |
| NextUI install + launch on Base OS | ✅ (`installer exited 0`, ~48 s) — validated with the earlier staged-payload flow; the current user-copies-frontend flow reuses the same install path but is not yet re-validated on hardware |
| Seamless static bootlogo → frontend hand-off | ✅ |
| Deep sleep (real suspend-to-RAM, ~0 drain / 35 min) | ✅ |
| WiFi unaided bring-up + stable association | ✅ (validated when the frontend's `wifi_init.sh` did the wait; the Base-OS-owned `wlan0` bring-up is not yet hardware-validated) |
| Dropbear SSH + sftp over WiFi | ✅ (SSH + sftp-server validated on hardware via Forklift and scp) |
| adb over USB (charge port, device role) | ✅ root shell and checksum-matched push/pull validated on RG40XXV with the cable connected before power-on; reconnect requires a cable-connected restart |
| USB mass storage | ✅ MENU-held maintenance boot exported TF1 p7 to macOS on RG40XXV; whole-TF2 policy is automated-tested but still needs real-card validation |
| GLES video / input / audio in NextUI | ✅ (NextUI runs; port already validated these) |
| Bluetooth audio pairing end-to-end | ⏳ daemons run; not yet paired on base OS |
| HDMI output | ✅ hotplug both directions on RG40XXV once `rcS` mounts `debugfs` (§2.7) |
| Exact deep-sleep standby µA (long sleep) | ⏳ counter too coarse for 35 min |
| Other StockMod H700 targets | 🧪 target-aware images generated/verified; BaseOS hardware validation pending |
| RG28XX rotated-panel splash | ✅ on the RG28XX (2026-07-26): pre-turned bootlogo and status pill both land upright in landscape ([04](04-boot-splash.md) §2.1) — the first BaseOS hardware validation on a second model |
| 1.0 seven-partition A/B layout | ✅ boots on RG40XXV; NextUI reports BaseOS 1.0.0 |
| Hidden GPT attributes accepted by the boot chain | ✅ (booted with attributes set) |
| One drive letter / no format prompts on Windows | ⏳ not yet checked on a Windows machine |
| `.bosupd` update applied on hardware | ✅ 1.0.0 → 1.0.1 on RG40XXV: write + verify 50.7 s, flip, reboot, trial boot 1 of 3, confirmed |
| Rootfs running from slot B | ✅ running at LBA 1482752 — partition 5 boots from either offset |
| `/data` survives a slot flip | ✅ the update log written before the flip was still there after it |
| Update trial + confirm on hardware | ✅ armed on the first boot of the new slot and cleared when the session started |

> **Standalone-repo changes not yet hardware-validated:** the split from NextUI moved
> two responsibilities into Base OS — (a) the frontend payload is no longer baked in
> (the user copies it after first-boot expansion), and (b) Base OS now brings `wlan0` up
> itself instead of relying on the frontend's wifi script. Both build green and pass the
> QEMU userspace smoke test, but need a hardware flash to confirm the first-boot
> user-copy flow and the WiFi timing (see [05](05-runtime-power-network.md) §3).

## 2. Bug log — the five flash rounds to first boot

The path to a booting image was a sequence of *silent* failures (frozen splash, no
console — `CONFIG_FRAMEBUFFER_CONSOLE` is off). Each was diagnosed by instrumenting a
layer, and each is now guarded:

1. **Modern ext4 features.** `mke2fs` 1.47 defaults (`metadata_csum`, `_seed`, `64bit`)
   aren't mountable by the 4.9 kernel. → classic 4.9-safe feature mask
   ([00](00-boot-chain-and-partitions.md) §3).
2. **Journal required.** p4 is an **Android boot image** embedding a vendor initramfs
   whose `/init` mounts root `data=ordered`; the kernel rejects that on a journal-less
   ext4. → keep the journal. (Root cause found by extracting p4 and reading the
   initramfs `/init` — the real boot contract.)
3. **`/init` must be a regular file.** The 2015 `switch_root` fails on our
   `/init → sbin/init` symlink chain. → `/init` is a real script, not a symlink.
4. **`expand-storage` not executable.** Shipped 0644; `rcS` guards the call with
   `[ -x ]`, so it silently never ran → first boot `NO SYSTEM FOUND`. → added to the
   rootfs chmod list **and a build guard that fails the build if any boot-critical
   script is non-executable.**
5. **Install-progress creep drew over NextUI.** A background `fbsplash` loop raced
   NextUI's first frame and left the splash stuck over its static menu. → removed;
   static `INSTALLING` frame only ([04](04-boot-splash.md) §5).
6. **A cached tool binary shipped against new scripts.** `work/tools/` was reused
   whenever the binaries merely *existed*, so editing `src/fbsplash.c` never rebuilt
   the one that shipped. A pre-pill `fbsplash` reached a device whose boot scripts
   already spoke the new contract: `--pill` fell into `atoi()` as progress 0, the
   message argument shifted by one, and a card-less boot showed the full-screen logo
   with one letter lit and `-1` for a caption — the real `INSERT SD CARD` silently
   discarded. → `work/tools/.stamp` records the source hashes
   (`tools/tools-stamp.sh`); `build-stockmod.sh` rebuilds on mismatch and
   `build-rootfs.sh` refuses to ship. The deeper fix is that the renderer now rejects
   option-shaped arguments instead of letting `atoi()` reinterpret them, so the same
   skew fails loudly and leaves the boot logo untouched. **Two lessons: existence is
   not freshness, and a CLI that parses with `atoi()` must reject what it doesn't
   understand.**
7. **HDMI went to the internal panel** (issue #10). Plugging a cable in was detected
   and the UI resized to 1280x720, but the picture stayed on the 640x480 LCD, squished;
   unplugging left it not filling the panel. The sunxi disp2 driver's only
   output-switch surface is `/sys/kernel/debug/dispdbg`, and **`rcS` never mounted
   `debugfs`** — on the stock OS systemd did. So the frontend's `SetHDMI()` wrote four
   files that did not exist, got no error it could act on, and carried on resizing the
   framebuffer and the DE layer against an output that had not moved. → `rcS` mounts
   `debugfs`; `validate-on-device.sh` now checks `dispdbg/command` is writable.
   **Lesson: an inherited-from-stock kernel interface is a dependency like any harvested
   library — the ones reached by path rather than by `ld.so` are exactly the ones the
   closure analysis misses.** (Consuming it silently is the other half of the bug: the
   frontend's fix was to notice, and to stop cropping the scanout layer to a
   framebuffer page nothing renders into.)

Debug technique that cracked the silent boots: **boot stock with the base-OS card in
the TF2 slot** — that runs our GPT / ext4 / binaries against the *real* kernel without
flashing, so `mount`, `chroot`, and the vendor initramfs's exact mount options can be
tested live. Plus (at the time) raw markers `dd`'d into the sacrificial `appfs` stub
sector — that partition is gone as of 1.0, its region being the second rootfs slot —
ext4
superblock mount-counts, and `fbsplash` breadcrumbs as boot-stage forensics.

## 3. Build / debug gotchas worth remembering

- ext4 for the 4.9 kernel: 4.9-safe feature mask **with** a journal.
- FAT `primary`: leave 1 MiB headroom so `mkfs.vfat` can't overrun into the backup GPT.
- The GPT is the only thing that selects which bytes become the root filesystem, and
  it is entirely ours to write. `root=/dev/mmcblk0p5` names a *number*, not an
  address — that one fact is what buys A/B updates on a bootloader with no A/B
  support (see [07](07-partition-layout-and-updates.md)).
- Stock ships all eight partitions as Microsoft Basic Data with attributes `0`, which
  is precisely why a stock-derived card makes Windows offer to format five of them.
  Attribute bits 62/63 on everything but the user FAT volume fix it at zero cost.
- BusyBox has `mkfs.vfat`/`mkdosfs`/`partprobe`/`blockdev`/`killall` applets — no need
  to harvest dosfstools for the runtime.
- BusyBox `cp` has no `--sparse`; use plain `cp` + `truncate` for sparse test images.
- Growing a partition while a sibling is mounted needs the **`BLKPG` ioctl**, not
  `partprobe` (which EBUSYs). `gptgrow` does BLKPG.
- Dropbear serves sftp: it execs the static OpenSSH `/usr/libexec/sftp-server` for the
  `sftp` subsystem (2024.85 default `SFTPSERVER_PATH`), so `sftp`/`scp` work directly.
- Do **not** try to force the sunxi USB role. Writing `usbc0/otg_role` (e.g.
  `echo usb_device > otg_role`) **wedges the writer in an uninterruptible D-state** on the
  4.9.170 vendor kernel — reproduced both with and without a gadget bound, and only a
  reboot clears the stuck process. Its siblings `usb_device`/`usb_host`/`usb_null` are
  **0400 read-triggers** — merely `cat`-ing one switches the role (a `cat usb_host` wedged
  the port). The adb gadget instead binds to the always-present UDC and lets the manager
  auto-select peripheral mode on cable attach — no role write needed, and charging on the
  shared port is undisturbed. (Real path is `/sys/devices/platform/soc/usbc0` via the
  `/sys/bus/platform/devices/usbc0` symlink; the earlier `/sys/devices/platform/usbc0`
  guess did not exist, which is how the bad `otg_role` write got masked at first.)
- Configfs attribute `stat` sizes are synthetic. In particular, `test -s g1/UDC`
  returns true even when reading the file yields an empty value after disconnect.
  Test the contents. This was the hidden reason the first reconnect implementation
  treated an unbound gadget as bound.
- Reconnect recovery is deliberately outside the supported contract. The sunxi
  manager clears `g1/UDC` on disconnect, but a rebinder cannot repair cases where a
  later attach selects host role. A permanent listener would add partial recovery
  while the one shared port must still support intentional OTG devices. Connect the
  host cable before power-on; after a disconnect, restart with it connected.
- The repo shell is **fish**, which doesn't word-split variables — inline `ssh -o`
  options, never store them in a var.
- The QEMU smoke test exercises generic userspace, not the vendor kernel or hardware.
  During optional hardware validation, chroot-testing the harvest remains valuable
  after manifest changes (it previously caught the `ld-linux` interpreter symlink
  and `bluetoothctl`'s libreadline/libtinfo gaps).
- NextUI hook dirs (`run_hooks.sh`) only execute `*.sh` files.
- **A panel's dimensions do not tell you which way it is mounted.** The RG28XX reports
  480×640 and is held in landscape; every geometry-aware thing BaseOS drew was upright
  in framebuffer coordinates and therefore sideways on the glass. The vendor's own
  `bootlogo.bmp` is the cheapest oracle for the direction — extract it from p2 and see
  which way its artwork is stored ([04](04-boot-splash.md) §2.1).

## 4. Remaining polish / roadmap

- **Hardware-validate 1.0.** Three questions, one flash each: do the GPT attribute
  bits boot; may partition 5 start anywhere (flash an image built with the rootfs at
  the slot-B offset); does the seven-partition table boot. Then apply a real
  `.bosupd`. Until then 1.0 images are offline-verified only.
- **rootfs read-only.** The vendor initramfs mounts p5 rw; remount `ro` at the end of
  `rcS` for power-loss resilience (writable state is already tmpfs + `/data` + FAT).
- **BT-audio** end-to-end validation on base OS (HDMI is done — see §2.7).
- **Long deep-sleep measurement** for a projected-standby-days figure.
- **Other H700 variants.** The StockMod importer and device profiles now generate all
  ten supported images with per-target boot partitions, model identity and logos.
  Physical BaseOS validation beyond RG40XXV remains outstanding and must be recorded
  per model rather than inferred from successful image construction.
- **Silence boot breadcrumbs / release vs dev image split** (serial getty, dropbear
  SSH/sftp and adb-over-USB are dev conveniences).
- **PortMaster** later: the kernel already has squashfs + loop + overlay built in;
  glibc 2.35 is in place and `/etc/os-release` is now generated from `VERSION`. The
  512 MiB rootfs slot was sized with this in mind — 100 MB used, 5× headroom.
- **`/data` schema migration.** There is no versioning of `/data` yet. Acceptable
  while its contents are regenerable; needs a policy before anything in there becomes
  precious.

## 5. Relationship to frontends

BaseOS owns the hardware contract and OS tooling: GPT surgery, harvest closure, init,
boot splash and expand-to-fill. NextUI is the first-class initial frontend and the
source of the compatibility model contract, but it is installed onto the completed
card rather than embedded in this image. Other frontends can use the same small
session hand-off without becoming BaseOS build dependencies.
