# 02 — Image build & flash

Everything is runnable on macOS (Apple Silicon). All Linux/root work happens inside a
`--platform linux/arm64` Alpine container (native on Apple Silicon via OrbStack); no
loop mounts, no sudo, no privileged containers for the build itself. Filesystems are
populated **unprivileged** with `mke2fs -d` (ext4) and `mtools` / `mkfs.vfat --offset`
(FAT).

## 1. The pipeline

| script | when | does |
|---|---|---|
| `capture-stock.sh` | once per stock firmware version | tars the `manifest/harvest.list` allowlist off a live device over SSH → `work/stock-harvest.tar` (+ provenance in `work/capture-info.txt`) |
| `build-tools.sh` | once per toolchain bump | static **busybox** (Alpine pkg), static **dropbear** (built), static **fbsplash** (freetype linked in), static **gptgrow** → `work/tools/` |
| `build-rootfs.sh` | every rootfs change | assembles `work/rootfs.tar` from harvest + tools + overlay + generated `/etc`; runs `ldconfig`; **verifies every ELF's `ld.so` closure resolves in-tree**; runs a guard that fails the build if any boot-critical script is non-executable |
| `build-image.sh` | every image change | boot-prefix → regenerated GPTs → `mke2fs -d` p5 (rootfs) + p6 (payload) + p7 (`/data`) → `mkfs.vfat` p8 (empty) → overwrite the bootlogo on p2 → `work/nextui-h700-baseos.img` |

Inputs are content-addressed by sha256; the build is deterministic from three inputs:
`boot-prefix.img` (captured once), `stock-harvest.tar` (once per stock firmware), and
the NextUI release payload (normal `make` output, passed as `PAYLOAD_DIR`).

## 2. The tools (`tools/`)

- **`mkgpt.py`** — regenerates both GPTs of the freshly-sized image: keeps partition
  names / type & unique GUIDs / p1–p5 starts, resizes p5–p8, writes valid CRCs and a
  protective MBR. Conventions in [00](00-boot-chain-and-partitions.md) §5.
- **`gptgrow.c`** — zero-dependency **static** C tool that runs *on the device* on
  first boot to grow p8 to fill the whole card and live-resize it in the kernel via
  the `BLKPG` ioctl. Inline CRC32, rewrites both GPTs + protective MBR. Full design in
  [03](03-first-boot-and-expand.md).
- **`make-bootlogo.sh`** — regenerates `assets/bootlogo.bmp` from the `fbsplash`
  renderer so the hardware bootlogo equals fbsplash at rest. Run it whenever the
  splash design or font changes. See [04](04-boot-splash.md).
- **`fbsplash`** (source at `src/fbsplash.c`) — the framebuffer
  splash. Built here with freetype statically linked; also compilable with
  `-DFBSPLASH_TEST` to render to a PPM offline (no `/dev/fb0`) for design iteration.

## 3. Image geometry (small image, grown on device)

Because p8 is grown on first boot, it ships **small**, so the whole image is tiny:

| part | size in image | runtime |
|---|---|---|
| boot-prefix (GPT + boot0/U-Boot + p1–p4) | ~212 MiB | verbatim |
| p5 rootfs | 512 MiB ext4 (journal, 4.9-safe features) | mounted `/` |
| p6 appfs | 200 MiB ext4 — holds `/payload/` (the release tree) | mounted `ro` on first boot, copied to p8 |
| p7 UDISK | 128 MiB ext4 | `/data` persistent |
| p8 primary | 64 MiB empty FAT32 | **grown to fill the card + populated on first boot** |

Result: **~1.1 GiB apparent / ~400 MB real**, down from an earlier 6.8 GiB design
where p8 filled the image. Faster to flash, fits any card ≥ 2 GB.

**Sizing gotchas:**
- FAT32 needs 1 MiB of headroom below the partition end so `mkfs.vfat` alignment
  can't extend the filesystem past the partition into the backup GPT.
- ext4 features must be the 4.9-safe mask **with a journal** — see
  [00](00-boot-chain-and-partitions.md) §3. Getting this wrong is invisible until you
  flash (the kernel silently fails to mount root).

## 4. Verification baked into the build

`build-image.sh` self-checks: `sgdisk -v` (GPT integrity), `e2fsck -fn` on p5 and p6,
`debugfs` stats confirming `/init`, `/usr/sbin/gptgrow` and the p6 payload
(`MinUI.zip`) are present, and a FAT read of p8. `build-rootfs.sh` verifies the full
`ld.so` closure and the executable-bit guard. The QEMU smoke test
(`test-boot-qemu.sh`) boots the rootfs as an initramfs under a generic aarch64 kernel
and confirms `init → inittab → rcS` runs — but note it only exercises **static
busybox**; the harvest's dynamic binaries must be validated by an on-device chroot
(`validate-on-device.sh`), which is how two closure gaps were caught.

## 5. Flash

`flash-card.sh` is a guarded macOS flasher: it refuses internal/synthesised disks,
checks the target is ≥ the image, and requires the operator to type the disk
identifier back before `dd`-ing. **Never flash the stock TF1 card.**

```sh
./flash-card.sh              # no args: list removable candidates
./flash-card.sh diskN        # confirm by typing diskN, then dd + eject
```

Or any imager (Raspberry Pi Imager / balenaEtcher) with `work/nextui-h700-baseos.img`.

## 6. Dev/debug access

- **Serial**: 115200 8N1 getty on `ttyS0` (the debug UART).
- **SSH**: Dropbear starts once WiFi is up (enable WiFi in NextUI settings); login
  `root` / `root`. Dropbear has **no sftp-server**, and the macOS `scp` now defaults
  to SFTP — so push files with `cat local | ssh host 'cat > /path'` (or `scp -O`), not
  plain `scp`. Binary transfers over `cat | ssh` are byte-exact (verify with a
  checksum). Its host key differs from the stock OpenSSH, so use
  `-o UserKnownHostsFile=/dev/null` after a reflash.
- The rootfs is mountable rw (`mount -o remount,rw /`) for in-place edits during dev.
- Persistent dev state (BT pairings, dropbear host keys, entropy seed, `machine-id`)
  lives on `/data` (p7).
- **Shell gotcha**: the repo's default shell is `fish`, which does **not** word-split
  variables — never store `ssh -o …` options in a shell var and expand it; inline the
  flags.
