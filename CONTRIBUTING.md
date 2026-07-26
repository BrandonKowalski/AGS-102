# Contributing to BaseOS

## Development environment

Builds run on macOS using unprivileged Alpine containers (Docker or OrbStack), so
the host does not need sudo or loop mounts. Steps that build or execute AArch64
device binaries pin `linux/arm64` (native on Apple Silicon and emulated on Intel).
Preparation, image composition, bootlogo generation, and QEMU userspace smoke
tests pin the host architecture (`linux/amd64` on Intel and `linux/arm64` on Apple
Silicon) so those steps stay native.

Building does **not** need the StockMod firmware images. `./fetch-prepared.sh`
restores the prepared per-target inputs from a published bundle (~150 MB) instead
of ten 11.7 GB vendor images. Firmware is only needed to add a device or to move a
target onto a new vendor release; both are covered below.

## Building

```sh
./fetch-prepared.sh
./build-all.sh
```

That produces, for every model, the two files a release publishes:

```
work/<target>/baseos-<target>-<version>.img.zip   flash once
work/<target>/baseos-<target>-<version>.bosupd    every update after that
```

Both scripts take an optional target list, which is what you want while iterating:

```sh
./fetch-prepared.sh rg40xxv
./build-all.sh rg40xxv
./flash-card.sh rg40xxv diskN
```

`build-all.sh` is the existing per-target chain — rootfs, QEMU userspace smoke
test, image, update payload — plus packaging, and it rebuilds the shared tools
only when `src/` has moved. Those steps remain individually runnable:

```sh
./build-tools.sh
./build-rootfs.sh rg40xxv
./test-boot-qemu.sh rg40xxv
./build-image.sh rg40xxv
./build-update.sh rg40xxv
```

The release version lives in the repo-root `VERSION` file; `build-rootfs.sh` bakes
it and `git describe` into `/etc/baseos-release` and `/etc/os-release`.

Target IDs are:

| Device | Target ID |
|---|---|
| Anbernic RG28XX | `rg28xx` |
| Anbernic RG34XX | `rg34xx` |
| Anbernic RG34XX SP | `rg34xxsp` |
| Anbernic RG35XX Plus / RG35XX 2024 | `rg35xxplus` |
| Anbernic RG35XX H | `rg35xxh` |
| Anbernic RG35XX Pro | `rg35xxpro` |
| Anbernic RG35XX SP | `rg35xxsp` |
| Anbernic RG40XX H | `rg40xxh` |
| Anbernic RG40XX V | `rg40xxv` |
| Anbernic RG CubeXX | `rgcubexx` |

Each target's profile lives in `devices.json`. `panel_rotation_ccw` is the angle the
splash is turned through to land upright on a panel that is mounted turned — `90` on the
RG28XX, whose 480×640 panel is held in landscape, and `0` everywhere else. See
[docs/04-boot-splash.md](docs/04-boot-splash.md) §2.1 before changing it: the direction
is fixed by the vendor bootlogo, not by taste.

## The prepared-artifact cache

`prepare-stock.sh` derives exactly three things per target from a vendor image:
`boot-prefix.img`, `stock-harvest.tar` and `source.json`. The cache ships the first
two pre-made; the third is committed:

```
manifest/prepared/<target>.json   each target's source.json — the trust anchor
manifest/prepared/bundle.sha256   hash of the published bundle
manifest/prepared/bundle.url      where that bundle lives
```

Integrity is checked twice and both anchors are in git. `bundle.sha256` covers the
download; the size and SHA-256 of each artifact, recorded in the committed
`source.json`, cover the contents — and that second check is the one
`build-rootfs.sh` and `build-image.sh` already run on every build. A bad restore
therefore fails exactly where a bad preparation would.

The cache is an optimisation, never a source of truth: `prepare-stock.sh`
regenerates the same artifacts from the vendor image and must produce the same
hashes. `./fetch-prepared.sh --from <bundle>` uses a local bundle instead of
downloading, and refuses to overwrite a target you prepared locally from different
firmware unless you pass `--force`.

## Adding a device model

The only workflow that still needs a vendor `.img` — once, for one person.

```sh
# add the devices.json entry first: id, model, stockmod_prefix, model_string,
# bootlogo_width/height, panel_rotation_ccw
./prepare-stock.sh rgsp /path/to/RGSP-...-mod-....img
./verify-target.sh rgsp
./cache-pack.sh
./build-all.sh rgsp && ./validate-on-device.sh rgsp DEVICE_IP ROOT_PASSWORD
```

`cache-pack.sh` runs `verify-target.sh` over every target before packing, writes
the bundle to `work/prepared/`, and prints the `gh release create` and `git add`
commands to finish with. Artifact releases are tagged by date, `prepared-YYYYMMDD`.

## Tracking a new vendor firmware

Each target pins a specific vendor firmware through its committed `source.json`, so
a new Anbernic release changes nothing until you choose to take it — per target.

```sh
./prepare-stock.sh rg40xxv /path/to/RG40XXV-<new>.img
git diff manifest/prepared/rg40xxv.json    # exactly what moved
./verify-target.sh rg40xxv
./cache-pack.sh
./build-all.sh rg40xxv && ./validate-on-device.sh rg40xxv DEVICE_IP ROOT_PASSWORD
```

The diff is the review: partition geometry, artifact hashes and the vendor image's
own provenance all change visibly in one small file.

`verify-target.sh` gates the assumptions a refreshed firmware could silently
invalidate — the recorded partition layout, that p1 `special` is an empty ext4,
that p3 `env` still boots `/dev/mmcblk0p5` and still leaves `partitions=` for
U-Boot to synthesise from GPT names, and that the p4 kernel still exports every
symbol the harvested modules import with matching modversions CRCs. That last one
matters most: a refreshed kernel whose exports have moved ships modules that fail
to `insmod`, leaving a device with a dead GPU or no Wi-Fi and no other symptom.
`tools/kernel_abi.py` recovers the export table straight out of the vendor `Image`
(see its module docstring for how, given there is no `vmlinux` or `Module.symvers`)
and can also check one target's modules against another's kernel:

```sh
python3 tools/kernel_abi.py check rg34xxsp --modules-from rg40xxv
```

To prepare and build from firmware in one command, without the cache:

```sh
./build-stockmod.sh /path/to/firmware rg40xxv
```

## Testing

Run checks relevant to the files changed. The main test entry points are:

```sh
./test-prepare-stock.sh
./test-expand-storage.sh
./tests/test-boot-splash-policy.sh
./tests/test-splash-rotation.sh
./tests/test-baseos-ntp.sh
./tests/test-timedatectl.sh
./tests/test-rtc-utc-policy.sh
./tests/test-gpt-slot.sh
./tests/test-update-apply.sh
./tests/test-boot-menu-held.sh
./tests/test-usb-gadget-adb.sh
./tests/test-usb-storage-mode.sh
./test-boot-qemu.sh rg40xxv
./test-update-roundtrip.sh rg40xxv   # needs build-image.sh + build-update.sh first
./validate-on-device.sh rg40xxv DEVICE_IP ROOT_PASSWORD
```

## Boot-performance changes

The README tracks two different figures:

- Total duration from pressing power to NextUI, measured manually.
- Kernel-relative `boot-frontend-exec`, the repeatable BaseOS optimization target.

Update the README counter only after controlled, repeated measurements show a
substantial change beyond normal jitter. Record the previous total and briefly name
the change responsible. If an intentional trade-off makes boot slower, document the
reason and raise the acceptance ceiling explicitly.

The RG40XX V `boot-frontend-exec` acceptance ceiling is currently 3.00 seconds and is
enforced by `validate-on-device.sh`.

## Technical documentation

- [Boot chain and partitions](docs/00-boot-chain-and-partitions.md)
- [Root filesystem and init](docs/01-rootfs-and-init.md)
- [Image build and flashing](docs/02-image-build-and-flash.md)
- [First boot and storage expansion](docs/03-first-boot-and-expand.md)
- [Boot logo and exceptional status UI](docs/04-boot-splash.md)
- [Runtime, boot timing, power, and networking](docs/05-runtime-power-network.md)
- [Hardware status and lessons learned](docs/06-status-and-lessons.md)
- [Partition layout and A/B system updates](docs/07-partition-layout-and-updates.md)
- [USB adb and H700 OTG investigation](docs/08-usb-adb-and-otg.md)
