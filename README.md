# Base OS — a minimal stock-derived Linux for Allwinner H700 handhelds

A small, flashable SD-card image that cold-boots an Anbernic RG XX (Allwinner H700)
straight into a frontend in a few seconds, with full hardware functionality — GLES
video, audio, input, **real deep sleep**, WiFi, Bluetooth audio, HDMI — a tiny
footprint, and a comfortable build/dev/debug loop. It replaces the full Anbernic
stock OS and its `dmenu.bin` launch trampoline with an OS we fully control.

**Frontend-agnostic by design.** Base OS boots and hands off to a frontend; today
that frontend is **NextUI**, but the OS is deliberately independent of it (a custom
frontend, Emulation Station, or anything else can take its place — see the
[frontend hand-off](#frontend-integration) below).

**Approach — *harvest, don't fork.*** Keep the stock **boot chain, kernel and vendor
blobs byte-for-byte** (they give "perfect hardware support" — deep sleep included).
Replace the entire Ubuntu 22.04 userland with a minimal **BusyBox-init** rootfs
containing only the ~45 stock libraries and handful of daemons the frontend actually
needs, proven by an `ldd` closure computed on hardware. No systemd, no udev, no
NetworkManager, no apt.

**Status (2026-07-19): working end-to-end on real hardware** (Anbernic RG40XXV):
cold boot ~7 s to the frontend, first-boot auto-expand-to-fill of the data partition,
real suspend-to-RAM deep sleep, WiFi/SSH, seamless boot splash. Image ~1.1 GiB
apparent / ~400 MB real. Nothing is published upstream yet.

## Documentation

Full reference suite in [`docs/`](docs/):

| Doc | Contents |
|---|---|
| [00 — boot chain & partitions](docs/00-boot-chain-and-partitions.md) | GPT layout, `boot-prefix.img`, U-Boot env & cmdline, the hidden Android-bootimg **vendor initramfs**, ext4 feature/journal constraints |
| [01 — rootfs & init](docs/01-rootfs-and-init.md) | BusyBox init, the stock-harvest allowlist + closure, the overlay tree, `/init → rcS → nextui-session`, the service shims |
| [02 — image build & flash](docs/02-image-build-and-flash.md) | The build pipeline, the tools, the unprivileged container approach, verification, flashing, dev access |
| [03 — first boot & expand](docs/03-first-boot-and-expand.md) | First-boot expand-to-fill (`gptgrow` + BLKPG + `mkfs.vfat` + staged payload), the frontend install hand-off, idempotency |
| [04 — boot splash](docs/04-boot-splash.md) | The `fbsplash` renderer (Lexend via freetype, the illumination), the seamless bootlogo BMP, stage mapping, why the frontend's own install UI can't render here |
| [05 — runtime, power, network](docs/05-runtime-power-network.md) | Measured boot timing, the deep-sleep validation, WiFi bring-up + power-save, Bluetooth, the `mali_kbase` background-load win |
| [06 — status & lessons](docs/06-status-and-lessons.md) | Hardware-validation matrix, the chronological bug log with root causes, remaining polish, build/debug gotchas |

## Repository layout

```
build-tools.sh        static busybox + dropbear + fbsplash + gptgrow (in a container)
build-rootfs.sh       assemble + verify the minimal rootfs → work/rootfs.tar
build-image.sh        compose the flashable image (GPT, ext4, FAT, bootlogo)
capture-stock.sh      harvest the stock library/daemon set off a live device (SSH)
flash-card.sh         guarded macOS flasher (typed-disk confirmation)
test-boot-qemu.sh     userspace boot smoke test under QEMU
validate-on-device.sh on-device chroot validation of the harvest closure
manifest/harvest.list the stock-file allowlist
overlay/              our files that go into the rootfs (init, config, scripts)
assets/               boot.ttf (Lexend Light), bootlogo.bmp, OFL.txt
tools/                gptgrow.c, mkgpt.py, make-bootlogo.sh
src/fbsplash.c        the framebuffer boot-splash renderer
diagnostics/          sleep-drain measurement hooks
work/                 build outputs (git-ignored)
```

## Quick start

Everything runs on macOS (Apple Silicon); all Linux/root work happens inside a
`--platform linux/arm64` Alpine container (OrbStack), no sudo or loop mounts.

```sh
./capture-stock.sh        # once per stock firmware version (needs a live device)
./build-tools.sh          # once: static busybox / dropbear / fbsplash / gptgrow
./build-rootfs.sh         # assemble + verify the rootfs
PAYLOAD_DIR=/path/to/frontend-payload ./build-image.sh   # compose the image
./flash-card.sh diskN     # flash a spare card (never the stock card)
```

Insert into the **TF1** slot, power on. First boot auto-expands the data partition to
fill the card and installs the frontend (~1 min); every later boot is a few seconds
to the frontend. Full detail in [02](docs/02-image-build-and-flash.md) and
[03](docs/03-first-boot-and-expand.md).

## External inputs

The build depends on two things produced outside this repo:

- **`boot-prefix.img`** — the first 222,298,112 bytes of a stock card (GPT + boot0 +
  U-Boot + partitions 1–4), captured once per stock firmware version. Pass its path
  via `BOOT_PREFIX=…` (see [00](docs/00-boot-chain-and-partitions.md)).
- **The frontend payload** (`PAYLOAD_DIR`) — the SD-card tree the frontend installs
  from (for NextUI, its `build/BASE` output: `MinUI.zip` + `*.pakz` + the
  Bios/Roms/Saves skeleton). Base OS stages this on an internal partition and copies
  it to the data partition on first boot.

## Frontend integration

Base OS hands off to a frontend by `exec`-ing a launch script from the card
(`overlay/usr/sbin/nextui-session`). Today it targets NextUI's
`.system/h700/paks/MinUI.pak/launch.sh` and runs the NextUI installer, unchanged,
via a pair of service shims (`systemctl`, `setBluetooth.sh` — see
[01](docs/01-rootfs-and-init.md)). A different frontend swaps the session script and
its payload; the OS↔frontend contract is small (a launch entry point, the standard
`/mnt/SDCARD` card layout, the `/tmp/poweroff`·`/tmp/reboot` sentinels, evdev/ALSA/
disp2 device access). Making that contract explicit and frontend-neutral is the next
milestone as a custom frontend comes online.
