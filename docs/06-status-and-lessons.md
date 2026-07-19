# 06 — Status, bug log & lessons

## 1. Hardware-validation matrix (RG40XXV, 2026-07-19)

| capability | status |
|---|---|
| Regenerated-GPT boot (boot0/U-Boot/kernel accept it) | ✅ on a 64 GB card |
| Minimal rootfs mounts + BusyBox init → NextUI | ✅ cold boot 7.18 s |
| First-boot expand-to-fill (p8 68 MB → 62.8 GB) | ✅ |
| NextUI install + launch on Base OS | ✅ (`installer exited 0`, ~48 s) — validated with the earlier staged-payload flow; the current user-copies-frontend flow reuses the same install path but is not yet re-validated on hardware |
| Seamless bootlogo → fbsplash illumination | ✅ |
| Deep sleep (real suspend-to-RAM, ~0 drain / 35 min) | ✅ |
| WiFi unaided bring-up + stable association | ✅ (validated when the frontend's `wifi_init.sh` did the wait; the Base-OS-owned `wlan0` bring-up is not yet hardware-validated) |
| Dropbear SSH over WiFi | ✅ |
| GLES video / input / audio in NextUI | ✅ (NextUI runs; port already validated these) |
| Bluetooth audio pairing end-to-end | ⏳ daemons run; not yet paired on base OS |
| HDMI output | ⏳ not retested on base OS |
| Exact deep-sleep standby µA (long sleep) | ⏳ counter too coarse for 35 min |
| RG34XXSP / RG28XX / cube variants | ⏳ need per-device `boot-prefix` + `DEVICE=` |

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
   `/init → sbin/init` symlink chain. → `/init` is a real staged-marker script.
4. **`expand-storage` not executable.** Shipped 0644; `rcS` guards the call with
   `[ -x ]`, so it silently never ran → first boot `NO SYSTEM FOUND`. → added to the
   rootfs chmod list **and a build guard that fails the build if any boot-critical
   script is non-executable.**
5. **Install-progress creep drew over NextUI.** A background `fbsplash` loop raced
   NextUI's first frame and left the splash stuck over its static menu. → removed;
   static `INSTALLING` frame only ([04](04-boot-splash.md) §5).

Debug technique that cracked the silent boots: **boot stock with the base-OS card in
the TF2 slot** — that runs our GPT / ext4 / binaries against the *real* kernel without
flashing, so `mount`, `chroot`, and the vendor initramfs's exact mount options can be
tested live. Plus raw markers `dd`'d into the sacrificial p6 stub sector, ext4
superblock mount-counts, and `fbsplash` breadcrumbs as boot-stage forensics.

## 3. Build / debug gotchas worth remembering

- ext4 for the 4.9 kernel: 4.9-safe feature mask **with** a journal.
- FAT p8: leave 1 MiB headroom so `mkfs.vfat` can't overrun into the backup GPT.
- BusyBox has `mkfs.vfat`/`mkdosfs`/`partprobe`/`blockdev`/`killall` applets — no need
  to harvest dosfstools for the runtime.
- BusyBox `cp` has no `--sparse`; use plain `cp` + `truncate` for sparse test images.
- Growing a partition while a sibling is mounted needs the **`BLKPG` ioctl**, not
  `partprobe` (which EBUSYs). `gptgrow` does BLKPG.
- Dropbear has no sftp-server; push with `cat | ssh 'cat > f'` (or `scp -O`), verify
  with a checksum.
- The repo shell is **fish**, which doesn't word-split variables — inline `ssh -o`
  options, never store them in a var.
- The QEMU smoke test only exercises static busybox; **always chroot-test the harvest
  on the real device** after manifest changes (caught the `ld-linux` interp symlink
  and `bluetoothctl`'s libreadline/libtinfo gaps).
- NextUI hook dirs (`run_hooks.sh`) only execute `*.sh` files.

## 4. Remaining polish / roadmap

- **rootfs read-only.** The vendor initramfs mounts p5 rw; remount `ro` at the end of
  `rcS` for power-loss resilience (writable state is already tmpfs + `/data` + FAT).
- **HDMI + BT-audio** end-to-end validation on base OS.
- **Long deep-sleep measurement** for a projected-standby-days figure.
- **Other H700 variants** (RG34XXSP / RG28XX / cube): capture each device's
  `boot-prefix.img` (DTB/panel differences live in p2/p4) and bake its `DEVICE=` /
  model string into `/etc/baseos-release`.
- **Clean harvest provenance.** The current harvest was captured from the maintainer's
  stockmod RG40XXV; p5 libraries are believed stock-untouched (stockmod lives on
  p6/p8), but importing from a clean official `RG40XXV-V1.1.1.0` archive would make the
  provenance airtight.
- **Silence boot breadcrumbs / release vs dev image split** (serial getty + dropbear
  are dev conveniences).
- **PortMaster** later: the kernel already has squashfs + loop + overlay built in;
  glibc 2.35 and an `/etc/os-release` identity remain to be decided.

## 5. Relationship to NextOS

This base OS is the pragmatic v1 that proves the hardware contract and the tooling
(GPT surgery, harvest closure, init design, boot splash, expand-to-fill) on real
hardware, quickly. The fully-custom Buildroot **NextOS** plan (documented in the
NextUI repo under `docs/custom-os/`, branch `h700-custom-linux`) is the longer arc;
everything validated here — especially the boot-chain facts in
[00](00-boot-chain-and-partitions.md) and the deep-sleep proof in
[05](05-runtime-power-network.md) — de-risks it. Prior local experiments
`~/Code/Me/tonky-os` (Buildroot + BSP-bundle) and `~/Code/Me/tonky-grok`
(mainline-first) were surveyed; this base OS supersedes both as the working path.
