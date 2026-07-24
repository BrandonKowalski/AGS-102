# Contributing to BaseOS

## Development environment

Builds run on macOS using unprivileged Alpine containers (Docker or OrbStack), so
the host does not need sudo or loop mounts. Steps that build or execute AArch64
device binaries pin `linux/arm64` (native on Apple Silicon and emulated on Intel).
Preparation, image composition, bootlogo generation, and QEMU userspace smoke
tests pin the host architecture (`linux/amd64` on Intel and `linux/arm64` on Apple
Silicon) so those steps stay native.

Each target requires an extracted StockMod `.img`. Multipart `.7z` downloads must be
extracted first.

## Building an image

```sh
./prepare-stock.sh rg40xxv /path/to/RG40XXV-...-mod-....img
./build-tools.sh
./build-rootfs.sh rg40xxv
./test-boot-qemu.sh rg40xxv
./build-image.sh rg40xxv
./flash-card.sh rg40xxv diskN
```

The release version lives in the repo-root `VERSION` file; `build-rootfs.sh` bakes it
and `git describe` into `/etc/baseos-release` and `/etc/os-release`. To also produce
the update payload users copy onto their card:

```sh
./build-update.sh rg40xxv
```

The image is written to `work/rg40xxv/baseos-rg40xxv.img`. To prepare and build in
one command:

```sh
./build-stockmod.sh /path/to/firmware rg40xxv
```

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

## Testing

Run checks relevant to the files changed. The main test entry points are:

```sh
./test-prepare-stock.sh
./test-expand-storage.sh
./tests/test-boot-splash-policy.sh
./tests/test-baseos-ntp.sh
./tests/test-timedatectl.sh
./tests/test-gpt-slot.sh
./tests/test-update-apply.sh
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
