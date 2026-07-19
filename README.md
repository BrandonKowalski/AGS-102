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

**Approach — *harvest, don't fork.*** Prepare each target from an extracted StockMod
firmware image, retaining its **boot chain, kernel and vendor blobs** (they give
"perfect hardware support" — deep sleep included).
Replace the entire Ubuntu 22.04 userland with a minimal **BusyBox-init** rootfs
containing only the ~45 stock libraries and handful of daemons the frontend actually
needs. No systemd, no udev, no NetworkManager, no apt. Building requires no live
device, SSH credentials, or manually captured boot prefix.

**Status (2026-07-19): working end-to-end on real hardware** (Anbernic RG40XXV):
cold boot ~7 s to the frontend, first-boot auto-expand-to-fill of the data partition,
real suspend-to-RAM deep sleep, WiFi/SSH, seamless boot splash. Image ~1.1 GiB
apparent / ~400 MB real. The build pipeline supports all ten current StockMod H700
targets; other models remain generated/verified rather than BaseOS hardware-validated
until they are flashed and tested.

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
prepare-stock.sh      derive one target's inputs from a StockMod .img
build-stockmod.sh     prepare/build/test every target (or a selected subset)
build-rootfs.sh       assemble + verify one target's minimal rootfs
build-image.sh        compose one target's image (GPT, ext4, FAT, bootlogo)
flash-card.sh         guarded macOS flasher (typed-disk confirmation)
test-boot-qemu.sh     userspace boot smoke test under QEMU
validate-on-device.sh on-device chroot validation of the harvest closure
devices.json          target IDs, filename matching, identity, logo dimensions
manifest/harvest.list the stock-file allowlist
overlay/              our files that go into the rootfs (init, config, scripts)
assets/               boot.ttf (Lexend Light), legacy 640×480 logo reference, OFL.txt
tools/                gptgrow.c, mkgpt.py, make-bootlogo.sh
src/fbsplash.c        the framebuffer boot-splash renderer
diagnostics/          sleep-drain measurement hooks
work/                 build outputs (git-ignored)
```

## Quick start

Everything runs on macOS (Apple Silicon); all Linux/root work happens inside a
`--platform linux/arm64` Alpine container (OrbStack), no sudo or loop mounts.

```sh
# Extract the StockMod .7z.001/.7z.002 set first; BaseOS consumes the .img.
./prepare-stock.sh rg40xxv /path/to/RG40XXV-...-mod-....img
./build-tools.sh
./build-rootfs.sh rg40xxv
./test-boot-qemu.sh rg40xxv
./build-image.sh rg40xxv
./flash-card.sh rg40xxv diskN
```

The image is written to `work/rg40xxv/baseos-rg40xxv.img`. Replace `rg40xxv` with
another supported target ID throughout. For the same workflow in one command, use
`./build-stockmod.sh /path/to/firmware rg40xxv`.

For a complete set, put one extracted StockMod `.img` per model in one directory and
run `./build-stockmod.sh /path/to/firmware`. Add target IDs after the directory to
build a subset. The command rejects missing or ambiguous inputs before preparation.
Supported IDs are `rg28xx`, `rg34xx`, `rg34xxsp`, `rg35xxplus` (Plus and 2024),
`rg35xxh`, `rg35xxpro`, `rg35xxsp`, `rg40xxh`, `rg40xxv`, and `rgcubexx`.

Insert into the **TF1** slot, power on. The **first boot expands the data partition to
fill the whole card** (leaving it empty) and shows *COPY FRONTEND TO SD CARD*. Then:

1. Put the card in a computer — it now presents the full-capacity `BASEOS` volume.
2. Copy your frontend onto it (for NextUI: `MinUI.zip` + any `nextui.*.pakz`).
3. Reboot the handheld — Base OS installs/launches the frontend, and every later boot
   goes straight to it in a few seconds.

Full detail in [02](docs/02-image-build-and-flash.md) and
[03](docs/03-first-boot-and-expand.md).

## External inputs

Base OS depends on one external input per target: an **extracted StockMod `.img`**.
Multipart `.7z` downloads must be extracted first. `prepare-stock.sh` validates the
image, derives `boot-prefix.img` and `stock-harvest.tar`, and records the source name,
size, SHA-256, GPT layout and derived hashes in `work/<target>/source.json`. Provenance
is recorded as StockMod firmware; it does not claim to be an official Anbernic image.

Each output image bakes **no frontend** — the user copies one onto the card after first-boot
expansion, so Base OS has no build- or run-time dependency on NextUI (or any frontend).

## Frontend integration

Base OS hands off to a frontend by `exec`-ing a launch script from the card
(`overlay/usr/sbin/nextui-session`). Today it targets NextUI's
`.system/h700/paks/MinUI.pak/launch.sh` and runs the NextUI installer, unchanged, via a
pair of service shims (`systemctl`, `setBluetooth.sh` — see
[01](docs/01-rootfs-and-init.md)); it also owns the WiFi interface (`wlan0`) itself so a
frontend never has to race the module load (see [05](docs/05-runtime-power-network.md)).
A different frontend swaps the session script; the OS↔frontend contract is small (a
launch entry point, the standard `/mnt/SDCARD` card layout, the
`/tmp/poweroff`·`/tmp/reboot` sentinels, a ready `wlan0`, evdev/ALSA/disp2 device
access). Making that contract explicit and frontend-neutral is the next milestone as a
custom frontend comes online.
