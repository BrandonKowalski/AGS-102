# 00 — Boot chain & partitions (the immutable half)

Everything in this file is what we **keep byte-for-byte** from the stock firmware.
It is the part we cannot rebuild and the part that gives "perfect hardware support".
All facts verified live on the RG40XXV (stock firmware V1.1.1.0, kernel
`4.9.170 #16 SMP PREEMPT` built 2026-05-21) on 2026-07-19.

## 1. GPT / partition layout

The stock card is **GPT** (not MBR). Verified identical from the live device and from
the captured `boot-prefix.img`:

| # | name | start LBA | size (stock) | contents | our image |
|---|---|---|---|---|---|
| — | (gap) | 0–73727 | 36 MiB | protective MBR, primary GPT, **boot0 + U-Boot blobs** | verbatim |
| 1 | `special` | 73728 | 64 MiB | vendor special | verbatim |
| 2 | `boot-resource` | 204800 | 32 MiB | **vfat**: `bootlogo.bmp`, `fastbootlogo.bmp`, fonts, DTBs | verbatim, **except we overwrite `bootlogo.bmp`** (see [04](04-boot-splash.md)) |
| 3 | `env` | 270336 | 16 MiB | U-Boot environment (bootargs) | verbatim |
| 4 | `boot` | 303104 | 64 MiB | **Android boot image**: kernel + vendor initramfs | verbatim |
| 5 | `rootfs` | 434176 | 7 GiB stock | Ubuntu 22.04 (4.1 GB used) | **our 512 MiB minimal rootfs** |
| 6 | `appfs` | — | 4 GiB stock | stock frontend + emulators | **200 MiB ext4 — first-boot payload** |
| 7 | `UDISK` | — | 512 MiB stock | stock scratch/swap | **128 MiB ext4 — `/data` persistent state** |
| 8 | `primary` | — | rest | vfat ROMs partition | **64 MiB empty FAT32 — grown to fill the card on first boot** |

**Load-bearing constraints** (violating any of these bricks the boot):

- U-Boot builds the kernel cmdline's `partitions=` map **from the GPT partition
  names**, and `bootcmd` boots the partition *named* `boot` via `sunxi_flash`. So the
  partition **names, order, and type/unique GUIDs must be preserved**, and **p5 must
  start at LBA 434176** (`root=/dev/mmcblk0p5` is hard-coded in the env). Sizes of
  p5–p8 are free to change.
- The first **222,298,112 bytes** of the stock card (everything up to the start of
  p5) are captured once as `boot-prefix.img` (sha256 `01efe95d…`, stored under
  `~/Code/Me/tonky-os/dl/bsp/anbernic-rg40xxv/RG40XXV-V1.1.1.0-EN16GB-260521/`). Our
  image starts as a verbatim copy of this, then both GPTs are regenerated for the
  target size (see `tools/mkgpt.py` in [02](02-image-build-and-flash.md)).
- `bootdelay=0` already, so there's no U-Boot key-press window to shave.

### The env partition (p3) cmdline

Read raw from p3 (`dd if=/dev/mmcblk0p3 | strings`):

```
root=/dev/mmcblk0p5 rootwait quiet splash init=/init
partitions=special@mmcblk0p1:boot-resource@mmcblk0p2:env@mmcblk0p3:boot@mmcblk0p4:rootfs@mmcblk0p5:appfs@mmcblk0p6:UDISK@mmcblk0p7:primary@mmcblk0p8
console=ttyS0,115200 loglevel=4 cma=64M ... lcd_type=boe
```

We never modify p3. `quiet` suppresses kernel log spam; to debug boot, one can
temporarily remove it, but the image build never touches p3.

## 2. The hidden vendor initramfs (p4 is an Android boot image)

**This is the single most important and least obvious fact.** Partition 4 (`boot`)
is **not** a bare kernel — it is an **Android boot image** (`ANDROID!` magic) that
bundles the kernel **and a vendor initramfs**. Extracting it (2 KiB page size; kernel
then gzip'd ramdisk) reveals a small BusyBox-1.22 (2015) initramfs whose `/init`:

1. parses `root=` / `gpt=` / `console=` from `/proc/cmdline`;
2. runs `e2fsck -y` on the root device;
3. **mounts root with `-o rw,noatime,nodiratime,norelatime,noauto_da_alloc,barrier=0,data=ordered`**;
4. `mount --move /dev` and `exec switch_root /mnt /init`.

Two consequences drove real bugs (see [06](06-status-and-lessons.md)):

- **The root ext4 MUST have a journal.** The initramfs mounts with `data=ordered`,
  and the kernel *rejects* that on a journal-less filesystem
  (`EXT4-fs: can't mount with data=, fs mounted w/o journal`) — an eternal boot
  splash. So `mke2fs` for p5 must **not** pass `^has_journal`.
- **Our `/init` must be a regular file, not a symlink.** The 2015 `switch_root`
  chokes on our `/init → sbin/init → busybox` symlink chain (stock's single-hop
  symlink works; the exact difference is unproven). We ship `/init` as a real
  staged-marker script that `exec`s BusyBox init (see [01](01-rootfs-and-init.md)).

The vendor initramfs mounts root **read-write** (not read-only). We do not currently
remount it `ro` — see the read-only-hardening item in [06](06-status-and-lessons.md).

## 3. ext4 feature policy for the 4.9 BSP kernel

The vendor kernel is 4.9.170. Modern `mke2fs` (e2fsprogs 1.47) enables features it
cannot mount. All three of our ext4 partitions (p5/p6/p7) are created with:

```
-O ^metadata_csum,^metadata_csum_seed,^64bit,^orphan_file
```

i.e. the classic feature set (`ext_attr resize_inode dir_index filetype extent
flex_bg sparse_super large_file huge_file dir_nlink extra_isize`) **plus a journal**.
`metadata_csum` needs kernel crc32c the vendor kernel lacks; `64bit`/`orphan_file`
are similarly too new. Getting this wrong is invisible until you flash — the kernel
just fails to mount root and hangs on the splash.

Kernel config points confirmed from `/proc/config.gz` on the device:

- `CONFIG_DEVTMPFS=y` but `CONFIG_DEVTMPFS_MOUNT` is **not** set → we mount devtmpfs
  ourselves in `rcS`, and bake static `/dev/console` + `/dev/null` nodes as a cover.
- `CONFIG_FRAMEBUFFER_CONSOLE` is **not** set → no kernel text console on the LCD, so
  boot debugging can't rely on printk-on-panel; we use on-screen `fbsplash`
  breadcrumbs and raw markers instead (see [06](06-status-and-lessons.md)).
- exfat, squashfs, overlay, f2fs, loop are **built in** — this 2026 kernel has native
  exfat (correcting earlier port notes).

## 4. Kernel modules

Only **three** modules are loaded by the running system; everything else (disp2,
audiocodec, evdev inputs, AXP2202 PMIC/battery, suspend, all filesystems) is built
into the kernel:

| module | role | notes |
|---|---|---|
| `mali_kbase.ko` | Mali-G31 GPU (`/dev/mali0`) | ~17 MB; loaded in the background during `rcS` |
| `8821cs.ko` | RTL8821CS WiFi (SDIO) | WiFi firmware embedded in the module; loaded async |
| `rtl_btlpm.ko` | RTL8821C Bluetooth low-power handshake | loaded on BT enable |

Bluetooth controller firmware lives at `/lib/firmware/rtlbt/` (`rtlbt_fw`,
`rtlbt_config`), loaded by `rtk_hciattach -n -s 115200 ttyS1 rtk_h5`.

## 5. Regenerating the GPT for a different image size

`tools/mkgpt.py` reads the primary GPT from the copied `boot-prefix.img`, keeps the
partition names / type GUIDs / unique GUIDs and the p1–p5 start offsets, resizes
p5–p8, and writes valid primary + backup GPTs (correct CRCs) plus a protective MBR
covering the target size. Conventions (matched exactly by `gptgrow`, [03](03-first-boot-and-expand.md)):
8 entries × 128 B at LBA 2–3, first usable LBA 4, backup entries at `total-3..-2`,
backup header at `total-1`, last usable = `total-4`. This regenerated GPT is accepted
by boot0, U-Boot **and** the kernel — validated on hardware, including on a 64 GB card
whose stale foreign backup GPT sat far past our image's end.
